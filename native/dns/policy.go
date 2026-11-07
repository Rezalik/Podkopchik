package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"regexp"
	"sort"
	"strings"
)

const maxOffsets = 65536

var epochRE = regexp.MustCompile(`^[a-f0-9]{16}$`)
var labelRE = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

type group struct {
	Names     []string `json:"names"`
	Protected bool     `json:"protected"`
	Policy    string   `json:"policy,omitempty"`
}

type clientPolicy struct {
	CIDR   string `json:"cidr"`
	Direct bool   `json:"direct"`
}

type config struct {
	Epoch                 string         `json:"epoch"`
	Virtual               bool           `json:"virtual,omitempty"`
	VirtualWindow         []uint32       `json:"virtual_window,omitempty"`
	Listen                string         `json:"listen"`
	Listen6               string         `json:"listen6,omitempty"`
	Upstream              string         `json:"upstream"`
	Pools                 []string       `json:"pools"`
	PrivatePool           string         `json:"private_pool,omitempty"`
	RetiredPools          []string       `json:"retired_pools,omitempty"`
	Exclusions            []string       `json:"exclusions"`
	Groups                []group        `json:"groups"`
	ClientPolicies        []clientPolicy `json:"client_policies,omitempty"`
	DirectGrantsConfirmed bool           `json:"direct_grants_confirmed,omitempty"`
	ClassificationMode    string         `json:"classification_mode,omitempty"`
	MigrationRestriction  bool           `json:"migration_restrict_unknown,omitempty"`
	Persistent            bool           `json:"persistent,omitempty"`
}

type policy struct {
	config
	key            string
	names          map[string]int
	pools          map[bool]netip.Prefix
	excluded       []netip.Prefix
	retired        []netip.Prefix
	clientNetworks []netip.Prefix
	stamp          func() (bootStamp, error)
}

func compile(c config) (*policy, error) {
	if !epochRE.MatchString(c.Epoch) || len(c.Groups) > 512 || len(c.Pools) == 0 || len(c.Pools) > 2 ||
		len(c.Exclusions) > 1024 || len(c.RetiredPools) > 80 {
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
	scopedIPv4 := c.Listen == "172.31.252.1:24053" && c.Listen6 == "" && len(c.Pools) == 1 &&
		c.Pools[0] == "172.31.253.0/24" && c.PrivatePool == c.Pools[0]
	if c.Virtual && !scopedIPv4 {
		return nil, errors.New("virtual DNS requires the dedicated IPv4 listener and pool")
	}
	if len(c.VirtualWindow) != 0 && (!scopedIPv4 || len(c.VirtualWindow) != 2 ||
		c.VirtualWindow[0] < 3 || c.VirtualWindow[0] > c.VirtualWindow[1] || c.VirtualWindow[1] > 254) {
		return nil, errors.New("invalid virtual address allocation window")
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
	p := &policy{config: c, names: map[string]int{}, pools: map[bool]netip.Prefix{}, stamp: systemBootStamp}
	if c.ClassificationMode != "" && c.ClassificationMode != "strict" && c.ClassificationMode != "compatible" {
		return nil, errors.New("invalid DNS classification mode")
	}
	if len(c.ClientPolicies) > 512 {
		return nil, errors.New("too many client DNS policies")
	}
	for _, client := range c.ClientPolicies {
		n, err := netip.ParsePrefix(client.CIDR)
		if err != nil || n != n.Masked() || n.Addr().Is4In6() || client.Direct && !c.DirectGrantsConfirmed &&
			(c.ClassificationMode == "strict" || c.MigrationRestriction) {
			return nil, errors.New("invalid or unconfirmed client DNS policy")
		}
		p.clientNetworks = append(p.clientNetworks, n)
	}
	var approved netip.Prefix
	if c.PrivatePool != "" {
		n, err := netip.ParsePrefix(c.PrivatePool)
		if err != nil || n != n.Masked() || !n.Addr().Is4() || !n.Addr().IsPrivate() || n.Bits() < 16 || n.Bits() > 24 {
			return nil, errors.New("private pool must be an explicit RFC1918 /16 through /24")
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
	for _, raw := range c.RetiredPools {
		n, err := netip.ParsePrefix(raw)
		if err != nil || n.Bits() == 0 || n != n.Masked() || n.Addr().Is4In6() {
			return nil, errors.New("invalid retired synthetic prefix")
		}
		for _, pool := range p.pools {
			if pool.Overlaps(n) {
				return nil, errors.New("active pool overlaps retired synthetic prefix")
			}
		}
		p.retired = append(p.retired, n)
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
		if c.Persistent && (g.Policy == "" || len(g.Policy) > 80 || strings.ContainsAny(g.Policy, "\r\n|")) {
			return nil, errors.New("persistent DNS groups require stable routing policy identities")
		}
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

func (p *policy) ledgerKey() string {
	if !p.Persistent {
		return p.key
	}
	pools := append([]string(nil), p.Pools...)
	sort.Strings(pools)
	b, _ := json.Marshal([]any{"native-dns-namespace-v1", p.Epoch, pools})
	return fmt.Sprintf("%x", sha256.Sum256(b))
}

func (p *policy) directClient(remote net.Addr) bool {
	if remote == nil {
		return false
	}
	a, err := netip.ParseAddrPort(remote.String())
	if err != nil {
		return false
	}
	ip := a.Addr().Unmap().WithZone("")
	for i, n := range p.clientNetworks {
		if n.Contains(ip) {
			return p.ClientPolicies[i].Direct
		}
	}
	return false
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

func (p *policy) syntheticAddress(a netip.Addr) bool {
	for _, n := range p.pools {
		if n.Contains(a) {
			return true
		}
	}
	for _, n := range p.retired {
		if n.Contains(a) {
			return true
		}
	}
	return false
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
	if p.syntheticAddress(a) {
		return false
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
