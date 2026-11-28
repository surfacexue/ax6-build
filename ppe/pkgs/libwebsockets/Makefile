#
# 钉版：libwebsockets 4.3.3
#
# ── 为什么钉 ────────────────────────────────────────────────────────────
# ppe-nss 这条线跟 openwrt master，feeds 里的 libwebsockets 是 5.1.0。
# 5.x 改写了 external event loop 的行为，与 ttyd 1.7.7 的 uvwasi 主循环不兼容：
# 设备实测起动 9 ms 后 lws_context_destroy，exit_code 0，procd 无限重启。
# OpenWrt 24.10 稳定版是「lws 4.3.3 + ttyd 1.7.7 + libwebsockets-full」，
# 社区大范围验证可用，故钉回 4.3.3。
#
# ── 为什么不能只把 ttyd 依赖换成 libwebsockets-openssl ──────────────────
# ttyd 1.7.7 的 CMakeLists.txt:64 硬性要求 LWS_WITH_LIBUV：
#   libwebsockets was not build with libuv support (-DLWS_WITH_LIBUV=ON)
# openssl 变体没有 LIBUV，直接 FATAL_ERROR，编译必失败（run 46110723733 实测）。
# 而 ttyd 最新版就是 1.7.7（2024-03-30），没有 1.7.8+ 可升。
# 结论：ttyd 依赖必须保持 full，问题只能在 lws 版本上解。
#
# ── 覆盖方式 ────────────────────────────────────────────────────────────
# prepare.sh 在 `feeds update -a` 之后、`feeds install -a` 之前，
# 用本文件覆盖 feeds/packages/libs/libwebsockets/Makefile。
#
# 内容取自 openwrt/packages 分支 openwrt-24.10，仅一处改动：
#   上游 `-DISABLE_WERROR=ON` 少了一个 D（实际设成 ISABLE_WERROR，等于没生效），
#   此处改为正确的 `-DDISABLE_WERROR=ON`，在 gcc-14/gcc-15 下更稳。
#

include $(TOPDIR)/rules.mk

PKG_NAME:=libwebsockets
PKG_VERSION:=4.3.3
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_SUBDIR:=$(PKG_NAME)-$(PKG_VERSION)
PKG_SOURCE_URL:=https://codeload.github.com/warmcat/libwebsockets/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=6fd33527b410a37ebc91bb64ca51bdabab12b076bc99d153d7c5dd405e4bdf90
PKG_SOURCE_VERSION:=v$(PKG_VERSION)

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_BUILD_DEPENDS:=libubox

CMAKE_INSTALL:=1

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

CMAKE_OPTIONS += -DLWS_IPV6=$(if $(CONFIG_IPV6),ON,OFF)
CMAKE_OPTIONS += -DDISABLE_WERROR=ON
CMAKE_OPTIONS += -DCMAKE_BUILD_TYPE=Release
CMAKE_OPTIONS += -DLWS_WITH_EXTERNAL_POLL=ON
CMAKE_OPTIONS += -DLWS_WITH_ULOOP=ON

# turn off all test apps
CMAKE_OPTIONS += -DLWS_WITHOUT_TESTAPPS=ON
CMAKE_OPTIONS += -DLWS_WITHOUT_TEST_SERVER=ON
CMAKE_OPTIONS += -DLWS_WITHOUT_TEST_SERVER_EXTPOLL=ON
CMAKE_OPTIONS += -DLWS_WITHOUT_TEST_PING=ON
CMAKE_OPTIONS += -DLWS_WITHOUT_TEST_CLIENT=ON

define Package/libwebsockets/Default
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=libwebsockets
  DEPENDS:=+zlib +libcap +libubox
  URL:=https://libwebsockets.org
  MAINTAINER:=Karl Palsson
endef

define Package/libwebsockets-openssl
  $(call Package/libwebsockets/Default)
  TITLE += (OpenSSL)
  DEPENDS += +libopenssl
  VARIANT:=openssl
  CONFLICTS:=libwebsockets-full
endef

define Package/libwebsockets-mbedtls
  $(call Package/$(PKG_NAME)/Default)
  TITLE += (mbedTLS)
  DEPENDS += +libmbedtls
  VARIANT:=mbedtls
  PROVIDES:=libwebsockets
  CONFLICTS:=libwebsockets-openssl
endef

define Package/libwebsockets-full
  $(call Package/libwebsockets/Default)
  TITLE += (Full - OpenSSL, libuv, plugins, CGI)
  DEPENDS += +libopenssl +libuv
  VARIANT:=full
  PROVIDES:=libwebsockets libwebsockets-openssl
endef

ifeq ($(BUILD_VARIANT),openssl)
  CMAKE_OPTIONS += -DLWS_OPENSSL_CLIENT_CERTS=/etc/ssl/certs
  CMAKE_OPTIONS += -DLWS_WITH_SSL=ON
endif

ifeq ($(BUILD_VARIANT),mbedtls)
  CMAKE_OPTIONS += -DLWS_WITH_MBEDTLS=1
endif

ifeq ($(BUILD_VARIANT),full)
  CMAKE_OPTIONS += -DLWS_OPENSSL_CLIENT_CERTS=/etc/ssl/certs
  CMAKE_OPTIONS += -DLWS_WITH_SSL=ON
  CMAKE_OPTIONS += -DLWS_WITH_LIBUV=ON
  CMAKE_OPTIONS += -DLWS_WITH_PLUGINS=ON
  CMAKE_OPTIONS += -DLWS_WITH_SERVER_STATUS=ON
  CMAKE_OPTIONS += -DLWS_WITH_ACCESS_LOG=ON
  CMAKE_OPTIONS += -DLWS_WITH_CGI=ON
  CMAKE_OPTIONS += -DLWS_UNIX_SOCK=ON
endif

define Package/libwebsockets/install
  $(INSTALL_DIR) $(1)/usr/lib
  $(CP) $(PKG_INSTALL_DIR)/usr/lib/libwebsockets*.so* $(1)/usr/lib/
endef

Package/libwebsockets-mbedtls/install = $(Package/libwebsockets/install)

Package/libwebsockets-openssl/install = $(Package/libwebsockets/install)

define Package/libwebsockets-full/install
  $(call Package/libwebsockets/install,$(1))
  $(CP) $(PKG_INSTALL_DIR)/usr/lib/libwebsockets-evlib_uv.so* $(1)/usr/lib
endef

$(eval $(call BuildPackage,libwebsockets-openssl))
$(eval $(call BuildPackage,libwebsockets-mbedtls))
$(eval $(call BuildPackage,libwebsockets-full))
