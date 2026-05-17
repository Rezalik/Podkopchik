include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-podkopchik
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Podkopchik maintainers

LUCI_TITLE:=Podkopchik transparent routing for Xray VLESS
LUCI_DEPENDS:=+luci-base +rpcd +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +curl +ca-bundle +jsonfilter +nftables +firewall4 +dnsmasq +xray-core
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
