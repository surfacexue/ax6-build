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

# fullconenat-nft 的来源钉死到 commit，避免上游分支漂移导致内容变化
IMM_SRC_SHA="${IMM_SRC_SHA:-b1088b5661bf257b3e89f8537df906a67b8e7289}"
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

echo '===== 4/6 取 fullconenat-nft（kmod-nft-fullcone，含 6.12+ 内核补丁）====='
# 该包在任何 openwrt feed 里都没有，只有 ImmortalWrt 树内维护；目录里只有
# Makefile + patches/，直接按 commit 拉两个文件即可，不必 clone 整棵树。
fcn_dir="package/ax6-pkgs/fullconenat-nft"
fcn_url="https://raw.githubusercontent.com/immortalwrt/immortalwrt/${IMM_SRC_SHA}/package/network/utils/fullconenat-nft"
mkdir -p "$fcn_dir/patches"
fetch() {
  curl -fsSL --retry 3 --retry-delay 2 --max-time 60 "$1" -o "$2" || {
    echo "ERROR: 下载失败 $1" >&2; exit 1; }
}
fetch "$fcn_url/Makefile" "$fcn_dir/Makefile"
fetch "$fcn_url/patches/010-fix-build-with-kernel-6.12.patch" \
      "$fcn_dir/patches/010-fix-build-with-kernel-6.12.patch"
grep -q 'KernelPackage/nft-fullcone' "$fcn_dir/Makefile" || {
  echo 'ERROR: fullconenat-nft/Makefile 不是预期的 kmod 包定义' >&2; exit 1; }
grep -q 'PKG_SOURCE_VERSION:=07d93b6' "$fcn_dir/Makefile" || {
  echo 'ERROR: fullconenat-nft 上游版本已变，需人工复核兼容性' >&2; exit 1; }
# 源码走 git clone 且上游仓库带 submodule/重打包，镜像哈希必对不上，直接跳过校验
sed -i 's|^PKG_MIRROR_HASH:=.*|PKG_MIRROR_HASH:=skip|' "$fcn_dir/Makefile"
grep -qx 'PKG_MIRROR_HASH:=skip' "$fcn_dir/Makefile" || {
  echo 'ERROR: PKG_MIRROR_HASH 未能改为 skip' >&2; exit 1; }
echo "OK: $(wc -l < "$fcn_dir/Makefile") 行 Makefile + 1 个 6.12+ 补丁已就位（$IMM_SRC_SHA）"

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
echo "fullconenat-nft 来自 immortalwrt@${IMM_SRC_SHA}:package/network/utils/fullconenat-nft"
echo '源准备完成。注意：编译成功不等于可刷，见 ppe/README.md 的验收清单。'
