# 第三条线：ppe-nss 6.18 + AX6 单槽 stock

本目录是 `ax6-build` 的第三条编译线，和另外两条互不干扰：

| 线 | workflow | 源码 | 内核 | 有线加速 | 无线 | 状态 |
|---|---|---|---|---|---|---|
| 主线 | `build.yml` | qosmio `25.12-nss` | 6.12.91 | **ECM**（qca-nss-drv） | ath11k 6.18.26 | 已编成 #9/#11，第 12 轮在跑 |
| 二线 | `build-libwrt.yml` | LibWrt `25.12-nss` | 6.12.116 | **ECM** | ath11k | 已就绪，未触发 |
| 三线 | `build-ppe.yml` | Julius `ppe-nss` @`7d65a3e` | **6.18** | **PPE/EDMA** | NSS WiFi | 本目录 |

**三条线里只有一条能刷。** ECM 与 PPE 是两套互斥的数据面架构，装了两套只会打架。

## 这条线存在的理由

前两条是 ECM 路线（供应商 NSS 主机驱动 + ECM 连接管理器），本线是 PPE 路线：
有线转发交给内核里的 **PPE/EDMA**，无线交给 **NSS WiFi 驱动**，不装 `qca-nss-ecm`。
好处是内核 6.18、组件更少；代价是它比 ECM 路线年轻得多，真机行为没被充分验证。

## 相对上游 Tiny 改了什么

基座是 `Steven-ZYC/AX6-OpenWrt-Tiny` @`57e4ff3` 的 `ppe-tiny`（无代理）。三处实质改动：

### 1. 体积 gate：28 MiB → 64 MiB

上游 `scripts/check-stock-image.py` 里：

```python
STOCK_MTD_BYTES   = 0x023C0000   # 35.75 MiB
MAX_FACTORY_BYTES = 28 * MIB
```

`0x023C0000` 是**小米原厂 A/B 双槽里单槽**的大小。本机实测：

```
mtd12 "rootfs" = 0x06640000 = 102.25 MiB
ubi0: 818 LEB × 126,976 B = 99.0 MiB，坏块 0，保留 PEB 20
当前卷：kernel 5.6 + rootfs 31.0 + rootfs_data 59.4 MiB
```

沿用 28 MiB 会把合法镜像判死，而真实上限是 99 MiB。本目录的版本改成：

```python
STOCK_MTD_BYTES   = 0x06640000   # 102.25 MiB，本机实测
MAX_FACTORY_BYTES = 64 * MIB     # 留 ~32 MiB 给 rootfs_data
```

**为什么不是 96 MiB**：818 LEB 里 kernel 固定 47。吃到 96 MiB 时 `rootfs_data` 只剩几 MiB，
overlay 一装包就满。64 MiB 时 rootfs 约占 512 LEB，overlay 还有约 32 MiB。

### 2. 单槽容错（不改就刷不进去）

上游 `prepare-ppe-experiment.sh` 写入的升级逻辑是 fail-closed：

```sh
redmi,ax6-stock)
    part_num="$(fw_printenv -n flag_boot_rootfs)" || return 1
```

本机 U-Boot 环境只有 `flag_ota_reboot=0`、`flag_boot_success=1`，**没有 `flag_boot_rootfs`**，
所以会 `return 1` 直接拒绝写入——不会变砖，但刷不动。

`scripts/prepare.sh` 第 4 步把它改成容错版：

```sh
part_num="$(fw_printenv -n flag_boot_rootfs 2>/dev/null || true)"
[ -z "$part_num" ] && part_num=0
```

空值按 0 处理，走 `CI_UBIPART="rootfs"`。这正是你当前固件（admincomps）能刷成功的逻辑——
它也做双槽判断，但没有 `|| return 1`，空值自然落到 `else` 分支。

### 3. NSS 固件 11.4.0.5-R6 → 12.5-R210

`nss-firmware` 包（2025.05.01）里内置四套固件，靠 Kconfig 选：

| 开关 | 版本 | 备注 |
|---|---|---|
| `NSS_FIRMWARE_VERSION_11_4` | 11.4.0.5 Release **6** | 默认值，**唯一支持 802.11s mesh** |
| `NSS_FIRMWARE_VERSION_12_1` | 12.1 Release 003 | 不支持 mesh |
| `NSS_FIRMWARE_VERSION_12_2` | 12.2 Release 161 | 不支持 mesh |
| `NSS_FIRMWARE_VERSION_12_5` | 12.5 Release **210** | 不支持 mesh，IPQ807x 最后一个公开版 |

**驱动会跟着切**：`qca-nss-drv` 的 Makefile 里只有 `ifeq ($(CONFIG_NSS_FIRMWARE_VERSION_11_4),y)`
才降级到 2021-09-13 的 `11.4.0.5` 源码，否则默认用 2024-11-13 的 `QSDK 12.5`。所以一个开关同时
换固件和驱动，不需要两处改。

主线（`ax6.config` 2183 行）和 LibWrt 线都显式写了 `CONFIG_NSS_FIRMWARE_VERSION_11_4=y`，
所以**一直用的是 2021 年的 11.4**，dmesg 里 `NSS FW Version: NSS.HK.11.4.0.5-6-R` 就是证据。

本线用 12.5。代价写在上面表里：**放弃 802.11s mesh**。本机不用 mesh，可以接受。

## 功能包（2026-11-25 增补）

基座 `ppe-tiny` 原本不带代理。按需求补了四组，源码与依赖归属：

| 功能 | 包 | 来源 | 说明 |
|---|---|---|---|
| 代理 | `luci-app-homeproxy` + `sing-box-tiny` | **ImmortalWrt `luci@openwrt-25.12`**（openwrt 官方 luci 没有）+ openwrt packages | 与 Tiny Plus 同一套；内核随包，装完可用 |
| | `kmod-nft-tproxy` `ucode-mod-digest` | openwrt 内核 / 核心 | HomeProxy 的透明代理与依赖 |
| 终端 / 文件 | `luci-app-ttyd` `ttyd` `luci-app-filemanager` | openwrt luci / packages | Tiny Plus 同款，无 SCP 客户端也能改配置 |
| UPnP | `luci-app-upnp` + `miniupnpd-nftables` | openwrt luci / packages | 游戏主机自动端口映射；nftables 变体，和 fw4 同栈 |
| FullCone | `kmod-nft-fullcone` + `luci-app-fullcone` | **本仓库 `ppe/pkgs/`**（任何 feed 都没有） | 内核模块源码 `fullcone-nat-nftables/nft-fullcone` @`07d93b6` + ImmortalWrt 两份补丁；用户态另有 nftables / libnftnl / firewall4 三个补丁 |
| 广告过滤 | `luci-app-adblock-fast` + `adblock-fast` | openwrt luci / packages | adblock-fast 走 dnsmasq，与 HomeProxy 的分流共存 |

没有装 `mosdns` / `v2ray-geodata`：那是分流 DNS 用的，多占约 20 MiB，本机走 PC 端代理用不上。

### FullCone 为什么是一整套，不是单个 kmod

官方 nftables 与 libnftnl 不认 `fullcone` 表达式，firewall4 也没有对应开关。
只装 `kmod-nft-fullcone` 的话，规则根本写不进去——`nft` 会报 unknown expression。
所以 `ppe/pkgs/` 里放了四件套，版本按本树核对过：

| 包 | 本树版本 | 补丁来源 |
|---|---|---|
| `libnftnl` | 1.3.2 | ImmortalWrt master（新增 `src/expr/fullcone.c`，需 `PKG_FIXUP:=autoreconf`） |
| `nftables` | 1.1.7 | ImmortalWrt master（语法、线性化、反线性化） |
| `firewall4` | `e6f600c4`（2026-10-29） | ImmortalWrt，按本树 commit 重生成；另给包加上 `+kmod-nft-fullcone` 依赖 |
| `fullconenat-nft` | 源码 `07d93b6` | ImmortalWrt master：`010`（6.12+ 签名）+ `011`（端口范围与 flags 修复） |

刷完后在 LuCI「网络 → FullCone NAT」里开关，或 `uci set firewall.@defaults[0].fullcone='1'`。
只对 UDP 生效（TCP 等价于 MASQUERADE）。

### 刷完后要手动做的两件事

1. **HomeProxy 节点**：LuCI「服务 → HomeProxy」里导入订阅或手填 VLESS Reality / Shadowsocks 节点。
   内核已随固件装好，不需要另下 sing-box。
2. **UPnP**：服务默认可能未启用，LuCI「服务 → UPnP」里勾「启用」并指定内网接口。

### FullCone 的编译风险已做自动化兜底

内核模块是 2023 年代码（上游仓库已 archived），用户态三个补丁也只是版本核对过、没在
6.18 上编过。workflow 在正式编译前先单独编 FullCone 四件套：

- 编过 → 继续，产物里 `UNVERIFIED.txt` 标 `FullCone: 含 …`；
- 报的是 `nft_ext_fullcone.c` / `nf_nat_fullcone.c` 的编译错误，或补丁打不上
  （`Hunk #N FAILED` / `patch does not apply`）→ 自动从 `.config` 剔除 FullCone 再整体编译，
  其余功能照常出固件，`UNVERIFIED.txt` 标 `FullCone: 已剔除`。

这样最坏情况不会白跑 90 分钟。

## 怎么跑

Actions → **Build AX6 PPE-NSS Firmware** → Run workflow。两个输入都留空即用默认钉住的 commit。

首轮 ccache 与 dl 都空，60–100 分钟。产物在 `out/`：

```
AX6-ppe-nss-factory.ubi
AX6-ppe-nss-sysupgrade.bin
AX6-ppe-nss.manifest
AX6-ppe-nss-IMAGE-AUDIT.md     ← 体积 gate 结果
build.config
SHA256SUMS
```

## 已知风险（按严重度）

| 风险 | 说明 |
|---|---|
| **PPE 真机行为未验证** | 上游 rc2 自己写着「Wi-Fi, DNS, LuCI, NSS/PPE and upgrade/rollback NOT validated on hardware」 |
| **单槽适配是推出来的** | 上游做的是 A/B 假设，本线改成单槽容错。逻辑对，但没在真机跑过 |
| **12.5 固件与 6.18 驱动配套性** | 上游 `NSS-12.5-K6.x` 分支标称面向 6.x，但 6.18 + 12.5 的组合没有公开验证记录 |
| **DSA 端口 MAC** | stock DTS 删掉了 ART nvmem，四个 swport 的 MAC 靠 U-Boot 打补丁，未实测 |
| **双槽镜像不通用** | `factory.ubi` 与 `sysupgrade.bin` 不能互换，LuCI 里只能选 sysupgrade |

## 刷之前必须做的

1. `sysupgrade -b` 全量配置备份 + `uci export`
2. `dd if=/dev/mtd12 | gzip` 备份当前 rootfs（102 MiB，回滚唯一依据）
3. 确认 `/proc/mtd` 里 mtd12 仍是 `0x06640000`
4. **先在另一台机器或准备好 U-Boot 救砖路径**——这条线的自升级逻辑没在真机验过

## 验收（刷完按顺序）

```sh
# 1 设备与内核
cat /tmp/sysinfo/board_name        # redmi,ax6-stock
uname -r                            # 6.18.x

# 2 NSS 固件版本必须是 12.5
dmesg | grep 'NSS FW Version'       # NSS.<platform>.12.5.0-210 或近似字样

# 3 PPE/EDMA 是否接管有线
lsmod | grep -E 'qca_nss|edma|ppe'
ethtool -S wan | grep -iE 'ppe|edma'   # 命中计数应随流量增长

# 4 无线
iw dev | grep -E 'Interface|ssid'
lsmod | grep -E 'ath11k|nss_wifi'

# 5 WireGuard / tailscale
wg --version; tailscale version
ls -l /etc/rc.d/S*tailscale

# 6 升级逻辑（不真升级，只看分支）
sed -n '/redmi,ax6-stock)/,/;;/p' /lib/upgrade/platform.sh
```

第 3 条是这条线的核心价值：PPE 生效时千兆转发几乎不吃 CPU。看 `top` 的 `si` 列，
满载时个位数为好，30%+ 说明 PPE 没接管。

## 回滚

刷回主线（ECM）或当前 admincomps 固件即可。`uboot` / `mibib` / `appsbl` 都没动，
救砖路径一直在。前提是第 2 条备份做过。
