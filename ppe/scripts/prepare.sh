#!/usr/bin/env bash
# 第三条线源准备：ppe-nss(6.18) + Redmi AX6 单槽 stock 布局 + NSS FW 12.5
# 在 ppe-source 目录内执行。需要环境变量 TINY_REPO 指向 Steven-ZYC/AX6-OpenWrt-Tiny 检出。
#
# 与上游 prepare-ppe-tiny.sh 的差异：
#   - 不并入 HomeProxy / sing-box（但补入 OpenClash 的 LuCI 包，见 3/6）
#   - 从 ImmortalWrt 25.12 取 Argon 主题 + luci-app-openclash（同一份克隆，不额外拉）
#   - 从 ImmortalWrt 25.12 取 fullconenat-nft（openwrt 任何 feed 都没有 kmod-nft-fullcone）
#   - 追加「单槽容错」修补：上游把 flag_boot_rootfs 缺失当致命错误，本机会因此拒刷
set -Eeuo pipefail

[[ -x scripts/feeds ]] || { echo 'ERROR: run inside OpenWrt source root' >&2; exit 1; }
: "${TINY_REPO:?TINY_REPO 未设置，应指向 AX6-OpenWrt-Tiny 的检出目录}"
[[ -f "$TINY_REPO/scripts/prepare-ppe-experiment.sh" ]] || {
  echo "ERROR: 缺少 $TINY_REPO/scripts/prepare-ppe-experiment.sh" >&2; exit 1; }

# fullconenat-nft 的来源由 ppe/pkgs/ 自己钉住（commit 与补丁都在仓库里），
# 这里只保留 ImmortalWrt luci 的版本变量给 argon / openclash 用
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

echo "===== 3/6 从 ImmortalWrt ${IMM_BRANCH} 取 Argon 主题 + OpenClash ====="
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone --depth 1 --single-branch --branch "$IMM_BRANCH" \
  https://github.com/immortalwrt/luci.git "$work/luci"
git -C "$work/luci" rev-parse HEAD > ./LUCI-SHA.txt
argon_src="$work/luci/themes/luci-theme-argon"
[[ -f "$argon_src/Makefile" ]] || { echo 'ERROR: 上游 luci 缺少 argon 主题' >&2; exit 1; }
mkdir -p package/ax6-luci
cp -a "$argon_src" package/ax6-luci/
python3 - <<'PY'
from pathlib import Path
p = Path('package/ax6-luci/luci-theme-argon/Makefile')
s = p.read_text()
old = 'include ../../luci.mk'
if s.count(old) != 1:
    raise SystemExit(f'ERROR: argon Makefile include 与预期不符（命中 {s.count(old)} 次）')
p.write_text(s.replace(old, 'include $(TOPDIR)/feeds/luci/luci.mk'))
print('OK: argon Makefile include 已改指 feeds/luci/luci.mk')
PY

# OpenClash：openwrt 官方 luci 没有这个包，只有 ImmortalWrt 的 luci 里有（纯 LuCI，不带内核）
openclash_src="$work/luci/applications/luci-app-openclash"
[[ -f "$openclash_src/Makefile" ]] || {
  echo 'ERROR: 上游 luci 缺少 luci-app-openclash（上游可能已挪位置）' >&2; exit 1; }
cp -a "$openclash_src" package/ax6-luci/
[[ -f package/ax6-luci/luci-app-openclash/Makefile ]] || {
  echo 'ERROR: 拷贝后仍无 luci-app-openclash/Makefile' >&2; exit 1; }
grep -q 'luci-compat' package/ax6-luci/luci-app-openclash/Makefile || {
  echo 'ERROR: luci-app-openclash 依赖声明与预期不符，需人工复核' >&2; exit 1; }
echo 'OK: luci-app-openclash 已并入 package/ax6-luci（内核 clash/mihomo 需在设备上另行上传）'

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

echo '===== 6/6 更新与安装 feeds ====='
./scripts/feeds update -a
./scripts/feeds install -a

echo '--- 溯源 ---'
git rev-parse HEAD
for feed in feeds/luci feeds/packages feeds/nss; do
  [[ -d "$feed" ]] && echo "$feed $(git -C "$feed" rev-parse HEAD)"
done
echo "immortalwrt/luci $(cat ./LUCI-SHA.txt)"
echo 'fullconenat-nft 来自本仓库 ppe/pkgs/（源码 07d93b6 + ImmortalWrt 的两份补丁）'
echo '源准备完成。注意：编译成功不等于可刷，见 ppe/README.md 的验收清单。'
