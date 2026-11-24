# qosmio 25.12-nss 移植说明

> 建立时间：2026-11-24
> 目标：用 `qosmio/openwrt-ipq` 的 `25.12-nss` 分支，产出可在现有 Redmi AX6（原厂分区）上刷写的 NSS 固件
> 状态：代码已就绪，**尚未推送编译**

---

## 1. 为什么换树

现在的编译链用的是 `TerryLip/AX6NSS-qosmio`，它最后提交是 **2025-06-11**，已停更 17 个月。
换到上游 `qosmio/openwrt-ipq`（TerryLip 是从它 fork 的）后，三个版本指标同时抬升：

| 项 | TerryLip（旧） | qosmio 25.12-nss（新） | 路由器当前在跑的 |
|---|---|---|---|
| 最后提交 | 2025-06-11 | 2026-06-06 | — |
| 内核 | 6.12.**31** | 6.12.**91** | 6.12.40 |
| mac80211 backports | 6.12.6 | **6.18.26** | 6.14.11 |
| NSS 驱动源日期 | 2021-09-13 | 2024-11-13 | — |
| tailscale | 1.104.6 | 1.104.1 | 未装 |
| golang | 1.23（需外部替换 27.x） | **1.27 自带** | — |
| AX6 原厂分区 | 有 `redmi_ax6-stock` | 只有扩容布局，需补 | — |

两个直接收益：

- **WiFi 驱动从 backports 6.12.6 跨到 6.18.26**，且 qosmio 这套带 `ath11k_nss`
  （无线流量也能进 NSS 加速，不再全靠 CPU）
- **不再需要替换 golang**，workflow 里那条 `git clone sbwml/packages_lang_golang` 整步删掉，
  少一个外部依赖、少一个失败点

---

## 2. 相对上游的四处改动

### 2.1 设备定义补丁（必须）

上游只有 `redmi_ax6`，它继承 `xiaomi_ax3600`，带着 `KERNEL_SIZE := 36608k` 和
`ARTIFACTS := initramfs-factory.ubi` —— 这是**扩容布局**（独立 kernel 分区）。
AX6 原厂分区没有独立 kernel 分区，必须清空这两项：

```makefile
define Device/redmi_ax6-stock
	$(call Device/redmi_ax6)
	DEVICE_VARIANT := (stock layout)
	DEVICE_ALT0_VENDOR := Redmi
	DEVICE_ALT0_MODEL := AX6
	DEVICE_ALT0_VARIANT := (custom U-Boot layout)
	KERNEL_SIZE :=
	ARTIFACTS :=
endef
TARGET_DEVICES += redmi_ax6-stock
```

补丁在 `patches/0001-add-redmi-ax6-stock.patch`，本地已用 `git apply --check` 验证可干净应用。
同时把 `redmi_ax6` 的 USB 包剔掉（`-kmod-usb3 -kmod-usb-dwc3 -kmod-usb-dwc3-qcom`），
AX6 没有 USB 口，这三条是从 TerryLip 树照搬的。

### 2.2 并入第三方包（必须）

`ax6.config` 里的 LuCI 应用（argon 主题、openclash、mosdns、turboacc、vlmcsd、cpufreq、
autocore、coremark、default-settings）**上游 qosmio 树没有**，它们是 TerryLip 放在
`package/new`（12 个目录）和 `package/emortal`（4 个目录）里的。

workflow 第 8 步在编译前把这两个目录整份拷进源码树：

```sh
git clone --depth 1 -b qualcommax-6.x-nss-wifi https://github.com/TerryLip/AX6NSS-qosmio.git /tmp/extrapkg
cp -a /tmp/extrapkg/package/new/. package/new/
cp -a /tmp/extrapkg/package/emortal/. package/emortal/
```

**不把这些包搬进本仓库**：目录里有源码和二进制，体积大；TerryLip 仓库是公开的，
按 commit 拉取可复现。

### 2.3 luci feed 指向 immortalwrt（必须）

`ax6.config` 里的 LuCI 选择来自 immortalwrt 分支（argon 主题官方 LuCI 没有）。
只换 luci，其余 feed 保持 openwrt-25.12：

```
src-git packages  → https://git.openwrt.org/feed/packages.git;openwrt-25.12（不变）
src-git luci      → https://github.com/immortalwrt/luci.git;openwrt-25.12（替换）
src-git nss_packages → https://github.com/qosmio/nss-packages.git;NSS-12.5-K6.x（不变）
```

### 2.4 config 的四处开关

| 符号 | 原值 | 新值 | 原因 |
|---|---|---|---|
| `kmod-nf-nathelper` | not set | **y** | RTSP/FTP/SIP/PPTP 穿透 |
| `kmod-nf-nathelper-extra` | not set | **y** | 同上（H.323 等） |
| `luci-ssl-openssl` | not set | **y** | 443 HTTPS；当前系统就在用 |

`kmod-nft-fullcone` 本来就是 `y`（fw4 的 nft 版 FullCone）。
`CONFIG_THERMAL` 系列本来就在 `target/linux/qualcommax/config-6.12` 里
（`CONFIG_THERMAL=y`、`CONFIG_CPU_THERMAL=y`、`CONFIG_QCOM_TSENS=y`），**不需要加 `kmod-thermal`**——
之前说「缺 thermal 框架」是判断错误，那是 grep 错了文件（查了 generic 而不是 target）。

---

## 3. 换树带来的一处硬冲突（已在 workflow 中修掉）

`luci-ssl-openssl` 在 immortalwrt 的 `openwrt-25.12` 分支里依赖 `+px5g-openssl`：

```
LUCI_DEPENDS:=+luci-light +libustream-openssl +px5g-openssl +luci-app-package-manager
```

但 openwrt-25.12 已把 px5g 拆成 `px5g-mbedtls` / `px5g-wolfssl`，`px5g-openssl`
**在以下四个地方全都不存在**（实测均 404）：

- openwrt/openwrt master
- openwrt/openwrt v25.12.6
- immortalwrt/packages openwrt-25.12
- qosmio/nss-packages

而官方 luci `openwrt-25.12` 的同一文件写的是 `+openssl-util`，包描述文本也写着
「用 openssl 命令行生成证书，而不是默认的 px5g」。

workflow 第 9 步做了一行替换（`+px5g-openssl` → `+openssl-util`），并在替换后硬校验。

---

## 4. 路由器当前实际状态（2026-11-24 21:30 实测）

用于判断「新固件会不会比现在差」：

```
内核        6.12.40（admincomps 25.12.6-NSS，r35452+21-42d80a41c9）
mac80211    6.12.40.6.14.11
rootfs      mtd12 = 06640000 (102 MiB)，/rom 31.0M，/overlay 53.1M
已装包      368 个（apk）
443         已监听（luci-ssl-openssl）
热控        12 个 zone（thermal_zone0..10 + nss-top-thermal）
/etc/config 有 argon cpufreq mosdns openclash sqm turboacc upnpd vlmcsd ...
```

**注意**：我们前几轮用 TerryLip 树编的那个固件（49.45 MiB，344 包）比现在这套**更旧**——
mac80211 6.12.6 vs 现在 6.14.11，且没有 openclash/mosdns/argon 等。
这也是「今晚先不刷」的正确理由。

---

## 5. 风险清单（按可能性排序）

| # | 风险 | 影响 | 现状 |
|---|---|---|---|
| 1 | `ax6.config` 里某些包在新树 + immortalwrt luci 下不存在，被 `defconfig` 静默丢弃 | 功能缺失（不会编不过） | workflow 有 warn 清单，会在 summary 里列出缺哪个 |
| 2 | `package/new` 里 2025-06 的包与 6.12.91 内核不兼容（`turboacc` 若含 kmod 部分） | 编译失败 | 第一轮见分晓，失败日志会定位到具体包 |
| 3 | ath11k 从 backports 6.12.6 跨到 6.18.26，AX6 的 qcn5024 驱动行为变化 | WiFi 不稳 | **只能实机验**，不刷机无法判断 |
| 4 | NSS 版本换代（drv 源日期 2021 → 2024） | 加速行为变化 | 刷后按 §6 三层证据验 |
| 5 | immortalwrt luci 的 `luci-app-*` 与 openwrt packages 的版本咬合 | 个别 app 打不开 | 只影响界面，不影响路由 |
| 6 | 首次编译冷启动，ccache 全失效 | 耗时 80–100 分钟 | 预期内 |

---

## 6. 编译成功后的验收（刷机前，本地做）

1. **看产物名**：必须含 `redmi_ax6-stock`，不含 `-stock` 的一律不能刷
2. **比 manifest 包数**：解压 `*.manifest`，确认关键包都在
   ```sh
   grep -E "^(kmod-qca-nss-drv|kmod-qca-nss-ecm|tailscale|kmod-tun|kmod-nft-fullcone|luci-ssl-openssl|luci-theme-argon|luci-app-openclash|luci-app-turboacc) " *.manifest
   ```
3. **拆 squashfs 看实体文件**（这一步最硬）：
   ```sh
   # 偏移按 bin 头部算，方法见之前验 Tailscale 的做法
   /usr/sbin/tailscaled、/lib/modules/6.12.91/wireguard.ko、/lib/modules/6.12.91/tun.ko
   ```
4. **对比包数**：新固件应与当前 368 包大致相当；少 20 个以上说明 config 被大量丢弃，回头查 summary 的 warn

## 7. 刷机（今晚不做，记录备用）

- `sysupgrade -n` 会清 `/etc/shadow`，刷完重设 root 密码；网段 192.168.2.x → 192.168.1.1
- naswan 四件套不在镜像里，刷完**先** `restore-rule.sh` **再** `deploy.sh`
- 刷前备份仍未做：`sysupgrade -b` + `uci export` + `dd if=/dev/mtd12`

## 8. 回滚

- 保留旧镜像：刷前 `dd if=/dev/mtd12 of=/tmp/mtd12.bin`（102 MB），失败时用 mtd write 写回
- 或刷回 admincomps 的 `25.12.6-NSS`（本地只有 9 KB 残包，需重下）
