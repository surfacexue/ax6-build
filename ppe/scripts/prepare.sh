#!/usr/bin/env bash
# 第三条线源准备：ppe-nss(6.18) + Redmi AX6 单槽 stock 布局 + NSS FW 12.5
# 在 ppe-source 目录内执行。需要环境变量 TINY_REPO 指向 Steven-ZYC/AX6-OpenWrt-Tiny 检出。
#
# 与上游 prepare-ppe-tiny.sh 的差异：
#   - 不并入 HomeProxy / sing-box（但补入 OpenClash 的 LuCI 包，见 3/6）
#   - 从 ImmortalWrt 25.12 取 Argon 主题 + luci-app-homeproxy（同一份克隆，不额外拉）
#   - 从 ImmortalWrt 25.12 取 fullconenat-nft（openwrt 任何 feed 都没有 kmod-nft-fullcone）
#   - 追加「单槽容错」修补：上游把 flag_boot_rootfs 缺失当致命错误，本机会因此拒刷
set -Eeuo pipefail

[[ -x scripts/feeds ]] || { echo 'ERROR: run inside OpenWrt source root' >&2; exit 1; }
: "${TINY_REPO:?TINY_REPO 未设置，应指向 AX6-OpenWrt-Tiny 的检出目录}"
[[ -f "$TINY_REPO/scripts/prepare-ppe-experiment.sh" ]] || {
  echo "ERROR: 缺少 $TINY_REPO/scripts/prepare-ppe-experiment.sh" >&2; exit 1; }

# fullconenat-nft 的来源由 ppe/pkgs/ 自己钉住（commit 与补丁都在仓库里），
# 这里只保留 ImmortalWrt luci 的版本变量给 argon / homeproxy 用
IMM_BRANCH="${IMM_BRANCH:-openwrt-25.12}"

echo '===== 1/6 stock 布局移植（复用上游 guarded 脚本）====='
bash "$TINY_REPO/scripts/prepare-ppe-experiment.sh"

echo '===== 2/6 追加 nss 包 feed ====='
if grep -q 'nss-packages' feeds.conf.default; then
  echo '已含 nss feed，跳过'
else
  cp feeds.conf.default feeds.conf
  echo 'src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;ppe-nss' >> feeds.conf
fi

echo "===== 3/6 从 ImmortalWrt ${IMM_BRANCH} 取 Argon 主题 + HomeProxy ====="
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone --depth 1 --single-branch --branch "$IMM_BRANCH" \
  https://github.com/immortalwrt/luci.git "$work/luci"
git -C "$work/luci" rev-parse HEAD > ./LUCI-SHA.txt
mkdir -p package/ax6-luci
for entry in themes/luci-theme-argon applications/luci-app-homeproxy; do
  [[ -f "$work/luci/$entry/Makefile" ]] || {
    echo "ERROR: 上游 luci 缺少 $entry（上游可能已挪位置）" >&2; exit 1; }
  cp -a "$work/luci/$entry" package/ax6-luci/
done
python3 - <<'PY'
from pathlib import Path

custom = Path('package/ax6-luci')
for name in ('luci-theme-argon', 'luci-app-homeproxy'):
    p = custom / name / 'Makefile'
    s = p.read_text()
    old = 'include ../../luci.mk'
    if s.count(old) != 1:
        raise SystemExit(f'ERROR: {p} 的 include 与预期不符（命中 {s.count(old)} 次）')
    p.write_text(s.replace(old, 'include $(TOPDIR)/feeds/luci/luci.mk'))
print('OK: argon / homeproxy 的 include 已改指 feeds/luci/luci.mk')

# HomeProxy 默认依赖完整 sing-box；本线只装 sing-box-tiny（体积与 AX6 内存都吃紧）
hp = custom / 'luci-app-homeproxy' / 'Makefile'
s = hp.read_text()
if s.count('+sing-box \\') != 1:
    raise SystemExit('ERROR: HomeProxy 依赖行变了，别把完整 sing-box 拖进来')
hp.write_text(s.replace('+sing-box \\', '+sing-box-tiny \\'))
if '+sing-box-tiny \\' not in hp.read_text():
    raise SystemExit('ERROR: 未能把 HomeProxy 依赖改成 sing-box-tiny')
print('OK: HomeProxy 已改依赖 sing-box-tiny')
PY

echo '===== 4/6 FullCone 全家桶（内核模块 + 用户态三件套 + LuCI 页）====='
# 只有内核模块是没用的：官方 nftables/libnftnl 不认 fullcone 表达式，firewall4 也没有
# 对应开关，规则根本写不进去。所以这一整套都随仓库走 ppe/pkgs/ 下，版本按本树核对过：
#   nftables 1.1.7 · libnftnl 1.3.2 · firewall4 e6f600c4
pkg_src="../ppe/pkgs"
[[ -d "$pkg_src" ]] || { echo "ERROR: 缺少 $pkg_src（ppe/pkgs 没随仓库带上来）" >&2; exit 1; }

fcn_dir="package/ax6-pkgs/fullconenat-nft"
mkdir -p package/ax6-pkgs
cp -a "$pkg_src/fullconenat-nft" "$fcn_dir"
grep -q 'KernelPackage/nft-fullcone' "$fcn_dir/Makefile" || {
  echo 'ERROR: fullconenat-nft/Makefile 不是预期的 kmod 包定义' >&2; exit 1; }
grep -qx 'PKG_SOURCE_VERSION:=07d93b626ce5ea885cd16f9ab07fac3213c355d9' \
     "$fcn_dir/Makefile" || {
  echo 'ERROR: fullconenat-nft 源码版本与预期不符，需人工复核' >&2; exit 1; }
grep -qx 'PKG_MIRROR_HASH:=skip' "$fcn_dir/Makefile" || {
  echo 'ERROR: PKG_MIRROR_HASH 不是 skip，git 源码校验会失败' >&2; exit 1; }
echo "OK: kmod-nft-fullcone 包定义 + $(ls "$fcn_dir/patches" | wc -l) 个内核补丁"

cp -a "$pkg_src/luci-app-fullcone" package/ax6-luci/
[[ -f package/ax6-luci/luci-app-fullcone/Makefile ]] || {
  echo 'ERROR: luci-app-fullcone 缺失' >&2; exit 1; }
echo 'OK: luci-app-fullcone 已并入 package/ax6-luci'

# 用户态三件套：补丁打进树内包，再按需要改两处 Makefile
#   libnftnl  加新源文件 src/expr/fullcone.c，票内自带的 Makefile.in 是旧的，必须 autoreconf
#   firewall4 要声明对内核模块的依赖，否则装了 fw4 没装 kmod 时 fw4 一 reload 就报错
install_patch() {
  local pkgdir="$1" patch="$2"
  [[ -d "$pkgdir" ]] || { echo "ERROR: 树里找不到 $pkgdir（上游可能挪了位置）" >&2; exit 1; }
  [[ -f "$patch" ]] || { echo "ERROR: 缺少补丁 $patch" >&2; exit 1; }
  mkdir -p "$pkgdir/patches"
  cp "$patch" "$pkgdir/patches/900-fullcone.patch"
}
install_patch package/libs/libnftnl                      "$pkg_src/libnftnl/fullcone.patch"
install_patch package/network/utils/nftables             "$pkg_src/nftables/fullcone.patch"
install_patch package/network/config/firewall4           "$pkg_src/firewall4/fullcone.patch"

grep -q '^PKG_FIXUP:=autoreconf' package/libs/libnftnl/Makefile \
  || sed -i '/^PKG_RELEASE:=/a PKG_FIXUP:=autoreconf' package/libs/libnftnl/Makefile
grep -q '^PKG_FIXUP:=autoreconf' package/libs/libnftnl/Makefile || {
  echo 'ERROR: libnftnl 未能加上 PKG_FIXUP:=autoreconf' >&2; exit 1; }

grep -q 'kmod-nft-fullcone' package/network/config/firewall4/Makefile \
  || sed -i 's/+kmod-nft-nat /+kmod-nft-nat +kmod-nft-fullcone /' \
           package/network/config/firewall4/Makefile
grep -q 'kmod-nft-fullcone' package/network/config/firewall4/Makefile || {
  echo 'ERROR: firewall4 未能加上 kmod-nft-fullcone 依赖' >&2; exit 1; }
echo 'OK: libnftnl/nftables/firewall4 补丁就位，autoreconf 与依赖已改'

echo '===== 5/6 单槽容错修补（关键，否则本机 sysupgrade 直接拒绝）====='
python3 - <<'PY'
from pathlib import Path

p = Path('target/linux/qualcommax/ipq807x/base-files/lib/upgrade/platform.sh')
s = p.read_text()

# 上游 prepare-ppe-experiment.sh 写入的是 fail-closed 版本：
#     part_num="$(fw_printenv -n flag_boot_rootfs)" || return 1
# 本机 U-Boot 只有 flag_ota_reboot / flag_boot_success，没有 flag_boot_rootfs，
# 直接 `return 1` 会让 sysupgrade 拒绝写入（不会变砖，但刷不进去）。
old = '\tredmi,ax6-stock)\n\t\tpart_num="$(fw_printenv -n flag_boot_rootfs)" || return 1'
new = (
    '\tredmi,ax6-stock)\n'
    '\t\t# 单槽机型补丁：U-Boot 无 flag_boot_rootfs 时按 0 处理，走 rootfs 分支\n'
    '\t\tpart_num="$(fw_printenv -n flag_boot_rootfs 2>/dev/null || true)"\n'
    '\t\t[ -z "$part_num" ] && part_num=0'
)
if s.count(old) != 1:
    raise SystemExit(
        f'ERROR: platform.sh 锚点与预期不符（命中 {s.count(old)} 次）；'
        '上游可能已改，人工复核后再编'
    )
s = s.replace(old, new)
p.write_text(s)

assert 'part_num="$(fw_printenv -n flag_boot_rootfs 2>/dev/null || true)"' in p.read_text()
print('OK: platform.sh 已改为单槽容错（空值 -> 0 -> CI_UBIPART=rootfs）')
PY

echo '===== 6/6 更新与安装 feeds（含 sing-box-tiny 精简）====='
./scripts/feeds update -a

# sing-box-tiny 在 packages 里默认带 with_quic（且未设 SMALL_FLASH 时还带 with_gvisor）。
# 本机只用 VLESS Reality / Shadowsocks，留 uTLS（指纹）与 Clash API（HomeProxy 状态）就够。
python3 - <<'PY'
from pathlib import Path

sb = Path('feeds/packages/net/sing-box/Makefile')
if not sb.is_file():
    raise SystemExit('ERROR: feeds/packages/net/sing-box/Makefile 不存在，feeds 结构变了')
s = sb.read_text()
old = """ifeq ($(BUILD_VARIANT),tiny)
ifeq ($(CONFIG_SMALL_FLASH),)
GO_PKG_TAGS:=with_gvisor
endif
GO_PKG_TAGS:=$(subst $(space),$(comma),$(strip $(GO_PKG_TAGS) with_quic with_utls with_clash_api badlinkname tfogo_checklinkname0))
else"""
new = """ifeq ($(BUILD_VARIANT),tiny)
# AX6 精简：只留 uTLS（Reality 指纹）与 Clash API（HomeProxy 状态），去掉 QUIC 与 gVisor
GO_PKG_TAGS:=$(subst $(space),$(comma),$(strip with_utls with_clash_api badlinkname tfogo_checklinkname0))
else"""
if s.count(old) == 1:
    sb.write_text(s.replace(old, new))
    print('OK: sing-box-tiny 已去掉 QUIC / gVisor')
else:
    # 只影响体积，不阻断构建；照实打出来，便于事后核对
    print('WARN: sing-box 的 tiny 分支与预期不符，未做精简（体积会大一些），当前分支内容：')
    inside = False
    for line in s.splitlines():
        if line.startswith('ifeq ($(BUILD_VARIANT),tiny)'):
            inside = True
        if inside:
            print('   ', line)
        if inside and line.startswith('else'):
            break
PY

# ttyd 1.7.7 与 libwebsockets 5.1.0 的事件循环冲突（2026-11-28 修）
#   full 变体编了 -DLWS_WITH_LIBUV=ON，ttyd 自己也链 libuv 并驱动它，
#   lws 起动时打 "elops_init_pt_uv: Using foreign event loop"，9 ms 后
#   lws_context_destroy，procd 无限重启（exit_code 0，从日志看不出是崩溃）。
#   ttyd 只需要 SSL + HTTP server，不需要 lws 的 plugins / CGI / uv 集成，
#   换到不带 LIBUV 的 openssl 变体即可；ttyd 自带的 libuv 照常用。
#   设备实测确认：整机只有 ttyd 依赖 libwebsockets-full，改这一个依赖不牵连别的包。
ttyd_mk='feeds/packages/utils/ttyd/Makefile'
if [[ -f "$ttyd_mk" ]] && grep -q '+libwebsockets-full' "$ttyd_mk"; then
  sed -i 's/+libwebsockets-full/+libwebsockets-openssl/' "$ttyd_mk"
  echo 'OK: ttyd 改用 libwebsockets-openssl（无 LIBUV，修复启动即销毁）'
elif [[ -f "$ttyd_mk" ]] && grep -q '+libwebsockets-openssl' "$ttyd_mk"; then
  echo 'OK: ttyd 已是 libwebsockets-openssl，跳过'
else
  echo 'WARN: 找不到 ttyd Makefile 或依赖写法变了，跳过（ttyd 可能仍启动即崩）' >&2
fi

./scripts/feeds install -a

echo '--- 溯源 ---'
git rev-parse HEAD
for feed in feeds/luci feeds/packages feeds/nss; do
  [[ -d "$feed" ]] && echo "$feed $(git -C "$feed" rev-parse HEAD)"
done
echo "immortalwrt/luci $(cat ./LUCI-SHA.txt)"
echo 'fullconenat-nft 来自本仓库 ppe/pkgs/（源码 07d93b6 + ImmortalWrt 的两份补丁）'
echo '===== 7/7 注入 files/ 覆盖（默认值修正 + pstore 转存）====='
if [[ -d ../ppe/files ]]; then
  mkdir -p files
  cp -a ../ppe/files/. files/
  # Windows 检出常丢可执行位，这里显式补回，否则 rc.local 与 uci-defaults 不执行
  chmod 755 files/etc/rc.local 2>/dev/null || true
  chmod 755 files/etc/uci-defaults/* 2>/dev/null || true
  echo "OK: 已注入 files/（$(find files -type f | wc -l) 个文件）"
  find files -type f | sed 's/^/    /'
else
  echo 'WARN: ../ppe/files 不存在，跳过 overlay 注入' >&2
fi

echo '源准备完成。注意：编译成功不等于可刷，见 ppe/README.md 的验收清单。'
