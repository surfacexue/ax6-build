#!/usr/bin/env bash
# 第三条线源准备：ppe-nss(6.18) + Redmi AX6 单槽 stock 布局 + NSS FW 12.5
# 在 ppe-source 目录内执行。需要环境变量 TINY_REPO 指向 Steven-ZYC/AX6-OpenWrt-Tiny 检出。
#
# 与上游 prepare-ppe-tiny.sh 的差异：
#   - 不并入 HomeProxy / sing-box（本线不带代理）
#   - 只从 ImmortalWrt 25.12 取 Argon 主题
#   - 追加「单槽容错」修补：上游把 flag_boot_rootfs 缺失当致命错误，本机会因此拒刷
set -Eeuo pipefail

[[ -x scripts/feeds ]] || { echo 'ERROR: run inside OpenWrt source root' >&2; exit 1; }
: "${TINY_REPO:?TINY_REPO 未设置，应指向 AX6-OpenWrt-Tiny 的检出目录}"
[[ -f "$TINY_REPO/scripts/prepare-ppe-experiment.sh" ]] || {
  echo "ERROR: 缺少 $TINY_REPO/scripts/prepare-ppe-experiment.sh" >&2; exit 1; }

echo '===== 1/5 stock 布局移植（复用上游 guarded 脚本）====='
bash "$TINY_REPO/scripts/prepare-ppe-experiment.sh"

echo '===== 2/5 追加 nss 包 feed ====='
if grep -q 'nss-packages' feeds.conf.default; then
  echo '已含 nss feed，跳过'
else
  cp feeds.conf.default feeds.conf
  echo 'src-git nss https://github.com/JuliusBairaktaris/nss-packages.git;ppe-nss' >> feeds.conf
fi

echo '===== 3/5 从 ImmortalWrt 25.12 取 Argon 主题 ====='
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git clone --depth 1 --single-branch --branch openwrt-25.12 \
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

echo '===== 4/5 单槽容错修补（关键，否则本机 sysupgrade 直接拒绝）====='
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

echo '===== 5/5 更新与安装 feeds ====='
./scripts/feeds update -a
./scripts/feeds install -a

echo '--- 溯源 ---'
git rev-parse HEAD
for feed in feeds/luci feeds/packages feeds/nss; do
  [[ -d "$feed" ]] && echo "$feed $(git -C "$feed" rev-parse HEAD)"
done
echo '源准备完成。注意：编译成功不等于可刷，见 ppe/README.md 的验收清单。'
