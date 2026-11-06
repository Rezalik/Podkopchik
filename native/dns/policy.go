package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"strings"
)

const maxOffsets = 65536

var epochRE = regexp.MustCompile(`^[a-f0-9]{16}$`)
var labelRE = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

type group struct {
	Names     []string `json:"names"`
	Protected bool     `json:"protected"`
}

type config struct {
	Epoch       string   `json:"epoch"`
	Virtual     bool     `json:"virtual,omitempty"`
	Listen      string   `json:"listen"`
	Listen6     string   `json:"listen6,omitempty"`
	Upstream    string   `json:"upstream"`
	Pools       []string `json:"pools"`
	PrivatePool string   `json:"private_pool,omitempty"`
	Exclusions  []string `json:"exclusions"`
	Groups      []group  `json:"groups"`
}

type policy struct {
	config
	key      string
	names    map[string]int
	pools    map[bool]netip.Prefix
	excluded []netip.Prefix
}

func compile(c config) (*policy, error) {
	if !epochRE.MatchString(c.Epoch) || len(c.Groups) > 512 || len(c.Pools) == 0 || len(c.Pools) > 2 || len(c.Exclusions) > 1024 {
		return nil, errors.New("invalid DNS policy bounds")
	}
	for _, raw := range []string{c.Listen, c.Upstream} {
		a, err := netip.ParseAddrPort(raw)
		if err != nil || a.Port() == 0 || a.Addr().Zone() != "" || a.Addr().Is4In6() || a.Addr().IsUnspecified() || a.Addr().IsMulticast() {
			return nil, errors.New("listener/upstream must be a concrete numeric address and port")
		}
	}
	listen := netip.MustParseAddrPort(c.Listen)
	upstream := netip.MustParseAddrPort(c.Upstream)
	if c.Virtual && (c.Listen != "172.31.252.1:24053" || c.Listen6 != "" || len(c.Pools) != 1 ||
		c.Pools[0] != "172.31.253.0/24" || c.PrivatePool != c.Pools[0]) {
		return nil, errors.New("virtual DNS requires the dedicated IPv4 listener and pool")
	}
	if listen == upstream {
		return nil, errors.New("DNS upstream loops to listener")
	}
	if c.Listen6 != "" {
		v6, err := netip.ParseAddrPort(c.Listen6)
		if err != nil || !listen.Addr().Is4() || !v6.Addr().Is6() || v6.Addr().Is4In6() || v6.Addr().Zone() != "" ||
			v6.Addr().IsUnspecified() || v6.Addr().IsMulticast() || v6.Port() != listen.Port() || v6 == upstream {
			return nil, errors.New("invalid second DNS listener")
		}
	}
	p := &policy{config: c, names: map[string]int{}, pools: map[bool]netip.Prefix{}}
	var approved netip.Prefix
	if c.PrivatePool != "" {
		n, err := netip.ParsePrefix(c.PrivatePool)
		if err != nil || n != n.Masked() || !n.Addr().Is4() || !n.Addr().IsPrivate() || n.Bits() != 24 {
			return nil, errors.New("private pool must be an explicit RFC1918 /24")
		}
		approved = n
	}
	for _, raw := range c.Pools {
		n, err := netip.ParsePrefix(raw)
		if err != nil || n != n.Masked() || (!allowedPool(n) && n != approved) || n.Bits() > n.Addr().BitLen()-3 || p.pools[n.Addr().Is4()].IsValid() {
			return nil, errors.New("invalid synthetic prefix")
		}
		p.pools[n.Addr().Is4()] = n
	}
	if approved.IsValid() && p.pools[true] != approved {
		return nil, errors.New("unused private pool approval")
	}
	for _, raw := range c.Exclusions {
		n, err := netip.ParsePrefix(raw)
		if err != nil || n.Addr().Is4In6() {
			return nil, errors.New("invalid DNS exclusion")
		}
		for _, pool := range p.pools {
			if pool.Overlaps(n) {
				return nil, errors.New("synthetic pool overlaps exclusion")
			}
		}
		p.excluded = append(p.excluded, n.Masked())
	}
	for i, g := range c.Groups {
		if len(g.Names) == 0 || len(g.Names) > 4096 || len(p.names)+len(g.Names) > 32768 {
			return nil, errors.New("invalid number of DNS names")
		}
		for _, n := range g.Names {
			if !validName(n) {
				return nil, errors.New("invalid DNS policy name")
			}
			if _, exists := p.names[n]; exists {
				return nil, errors.New("duplicate DNS policy name")
			}
			p.names[n] = i
		}
	}
	b, _ := json.Marshal(c)
	p.key = fmt.Sprintf("%x", sha256.Sum256(b))
	return p, nil
}

func allowedPool(n netip.Prefix) bool {
	for _, base := range []netip.Prefix{
		netip.MustParsePrefix("198.18.0.0/15"), netip.MustParsePrefix("100.64.0.0/10"),
		netip.MustParsePrefix("2001:2::/48"), netip.MustParsePrefix("fd00::/8"),
	} {
		if n.Bits() >= base.Bits() && base.Contains(n.Addr()) {
			return true
		}
	}
	return false
}

func validName(n string) bool {
	return strings.Contains(n, ".") && validQuestionName(n)
}

func validQuestionName(n string) bool {
	if len(n) > 253 {
		return false
	}
	for _, label := range strings.Split(n, ".") {
		if !labelRE.MatchString(label) {
			return false
		}
	}
	return true
}

func (p *policy) group(name string) int {
	for name = strings.TrimSuffix(strings.ToLower(name), "."); ; {
		if g, ok := p.names[name]; ok {
			return g
		}
		_, rest, ok := strings.Cut(name, ".")
		if !ok {
			return -1
		}
		name = rest
	}
}

func (p *policy) safeReal(a netip.Addr) bool {
	if !a.IsGlobalUnicast() || a.IsPrivate() || a.Is4In6() || a.IsLoopback() || a.Zone() != "" {
		return false
	}
	for _, n := range reservedReal {
		if n.Contains(a) {
			return false
		}
	}
	for _, n := range p.pools {
		if n.Contains(a) {
			return false
		}
	}
	for _, n := range p.excluded {
		if n.Contains(a) {
			return false
		}
	}
	return true
}

var reservedReal = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"), netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("198.18.0.0/15"), netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("2001:2::/48"),
}
