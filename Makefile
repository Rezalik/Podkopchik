include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-podkopchik
PKG_VERSION:=0.1.0-beta
ifeq ($(CONFIG_USE_APK),y)
  # APK uses _beta suffixes; the application still displays 0.1.0-beta.
  PKG_VERSION:=0.1.0_beta
endif
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Podkopchik maintainers

LUCI_TITLE:=Podkopchik transparent routing for Xray VLESS
LUCI_DEPENDS:=+luci-base +luci-light +rpcd +rpcd-mod-file +rpcd-mod-luci +uhttpd +ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-ubus +curl +ca-bundle +jsonfilter +nftables-json +kmod-nft-tproxy +firewall4 +ip-full +dnsmasq +xray-core +unzip
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
