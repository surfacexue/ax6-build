# AX6 NSS 固件云编译（qosmio 25.12-nss）

用 GitHub Actions 编译 **Redmi AX6 原厂分区（`redmi_ax6-stock`）** 的 NSS 固件。

- 源码：[`qosmio/openwrt-ipq`](https://github.com/qosmio/openwrt-ipq) 的 **`25.12-nss`** 分支
- 内核：**6.12.91**
- 无线：mac80211 backports **6.18.26**（ath11k）
- NSS：[`qosmio/nss-packages`](https://github.com/qosmio/nss-packages) `NSS-12.5-K6.x`

## 相对上游的四处改动

| # | 改动 | 位置 |
|---|---|---|
| 1 | 新增 `Device/redmi_ax6-stock` + `ipq8071-ax6-stock.dts`（上游只有扩容布局 `redmi_ax6`），并把 `redmi,ax6-stock` 加进网络/LED/校准/ubootenv/bootcount/platform.sh 的分支 | `patches/0001-add-redmi-ax6-stock.patch` |
| 2 | 并入 `package/new` + `package/emortal`（argon/openclash/mosdns/turboacc/vlmcsd/cpufreq/autocore/coremark/default-settings）；mosdns 的 LuCI 界面另从 `sbwml/luci-app-mosdns` 取 | workflow 第 8 步，运行时拉取 |
| 3 | `luci` feed 指向 immortalwrt 的 `openwrt-25.12`（官方 LuCI 没有 argon 主题） | workflow 第 7 步 |
| 4 | `ax6.config` 启用 WireGuard 四包、tailscale、`luci-ssl-openssl`、`kmod-nf-nathelper` 两件套 | `ax6.config` |

`packages` / `routing` / `telephony` / `video` 保持 openwrt-25.12 原样。**不再需要替换 golang**：
openwrt-25.12 的 packages feed 自带 `golang1.27`，满足 tailscale 1.104.1 的 `go 1.27.3` 要求。

## 怎么用

1. 仓库 **Actions** → **Build AX6 NSS Firmware** → **Run workflow**
2. 等待编译（4 核 runner，冷启动约 80–100 分钟；ccache 命中后约 60–70 分钟）
3. **Artifacts** 下载 `ax6-nss-wireguard-firmware`
4. 解压得 `*sysupgrade.bin`、`*.manifest`、`sha256sums`、`config.buildinfo`

## 文件说明

| 文件 | 用途 |
|---|---|
| `ax6.config` | 完整编译配置（371 个 `CONFIG_PACKAGE_*=y`） |
| `.github/workflows/build.yml` | 云编译流程（18 步） |
| `patches/0001-add-redmi-ax6-stock.patch` | 唯一的源码改动：原厂分区设备定义 + stock DTS + 板级分支 |

## 两个已修的坑（写进 workflow 里，不用再管）

1. **`luci-ssl-openssl` 的死依赖**
   immortalwrt 的 LuCI 还写着 `+px5g-openssl`，而 openwrt-25.12 已把 px5g 拆成
   `px5g-mbedtls` / `px5g-wolfssl`，`px5g-openssl` 在官方树、immortalwrt packages、
   qosmio nss-packages 里**全都不存在**。workflow 里按官方 25.12 的写法改回 `+openssl-util`。

2. **`luci.mk` 的 ucode 字节码约束**
   只有 openwrt 官方 LuCI 的 master 分支才有 `LUCI_UT_MIN_UCODE`，会把模板编成字节码；
   immortalwrt 的 `openwrt-25.12` 分支没有。workflow 里有硬校验，命中就中止而不是带病往下跑。

## 注意

- `make menuconfig` 在 CI 里无法交互，用 `make defconfig` 代替。
- 产物名是 `openwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade.bin`，
  **必须含 `-stock`**。命名容易误解：`-stock` 指**单卷 UBI**（custom U-Boot、大分区，
  rootfs 102 MiB，本机 `board_name=redmi,ax6-stock`）；不带 `-stock` 的 `redmi_ax6` 是
  **kernel 36 MB + rootfs 双卷**（expand layout）。两者互刷会 brick。
- 详细背景、风险清单、验收步骤见 `交接文档/qosmio-25.12-nss-移植说明.md`。
- 外部方案对比（Julius / LibWrt / Steven-ZYC / llz121517 等）见
  `交接文档/外部NSS方案调研-20261124.md`。

## 平行分支：LibWrt 25.12-nss

`libwrt/` 下是第二条编译线，用 `LiBwrt/LibWrt` 的 `25.12-nss`（内核 **6.12.116**）。
它的 `redmi_ax6-stock` 是树内原生的，luci/packages 本来就指向 immortalwrt 25.12，
所以主线那三处 workaround（换 luci、换 Go、修 px5g 死依赖）在这条线上都不需要。

- 触发方式：Actions → **Build AX6 LibWrt NSS Firmware** → Run workflow（**只手动触发**）
- 配置：`libwrt/configs/libwrt-ax6.config`
- 细节与风险：`libwrt/README.md`

## 第三条线：ppe-nss 6.18（PPE/EDMA，与 ECM 互斥）

`ppe/` 下是第三条编译线，基座 `JuliusBairaktaris/openwrt-ppe-nss` @`7d65a3e`（内核 **6.18**）。
与前两条的本质区别：**不装 `qca-nss-ecm`**，有线转发交给内核 PPE/EDMA，无线交给 NSS WiFi 驱动。
三条线里只有一条能刷，ECM 与 PPE 不能同时装。

相对上游 `Steven-ZYC/AX6-OpenWrt-Tiny` 改了三处：

1. **体积 gate 28 → 64 MiB**：28 MiB 是原厂 A/B 单槽（35.75 MiB）的保守值，本机 mtd12 实测 102.25 MiB
2. **单槽容错**：上游 `part_num="$(fw_printenv -n flag_boot_rootfs)" || return 1` 在本机会直接拒刷
   （本机 U-Boot 没有 `flag_boot_rootfs`），已改为空值按 0 处理
3. **NSS 固件 11.4.0.5-R6 → 12.5-R210**：一个 `CONFIG_NSS_FIRMWARE_VERSION_12_5` 同时切换固件与驱动
   （驱动 Makefile 里只有 11_4 才降级到 2021 源码）。代价是不支持 802.11s mesh

- 触发方式：push 到 `main` 且命中 `ppe/**`（自动），或 Actions → **Build AX6 PPE-NSS Firmware** → Run workflow（手动）
- 配置：`ppe/configs/ax6-ppe-nss.config`
- 细节、风险与验收：`ppe/README.md`


