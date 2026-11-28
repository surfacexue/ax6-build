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

`nss-firmware` 包（`PKG_VERSION:=2025.05.01`，来自 `JuliusBairaktaris/nss-packages@ppe-nss`）
里提供两档固件，靠 Kconfig 二选一：

| 开关 | 版本 | 备注 |
|---|---|---|
| `NSS_FIRMWARE_VERSION_12_5` | 12.5 Release **210** | 当前默认值；不支持 802.11s mesh |
| `NSS_FIRMWARE_VERSION_11_4` | 11.4.0.5 Release **6** | **唯一支持 802.11s mesh** 的一档 |

（2026-11-25 复核：上游这一版只剩这两档，早期曾出现过的 12.1 / 12.2 两条线已不在 Kconfig 里。）

**驱动会跟着切（仅 ECM 线适用）**：ECM 路线（主线 / LibWrt）的 `qca-nss-drv` Makefile 里只有
`ifeq ($(CONFIG_NSS_FIRMWARE_VERSION_11_4),y)` 才降级到 2021-09-13 的 `11.4.0.5` 源码，否则默认用
2024-11-13 的 `QSDK 12.5`。**本线是 PPE 架构，树里没有 `qca-nss-drv`**，`nss-firmware` 在这里
只提供固件 blob，驱动是树内 `package/kernel/nss-wifi-drv`。

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
6.18 上编过。workflow 分两层判：

1. **静态自检**（不依赖工具链，一定有结论）：三份补丁必须在位、`libnftnl` 补丁里真有
   `expr/fullcone`、`nftables` 补丁里真有 fullcone 语法、`firewall4` 的 Makefile 声明了
   `kmod-nft-fullcone` 依赖。缺任何一条就自动剔除 FullCone 再整体编译。
2. **试编译**（只在 `staging_dir/toolchain-*` 已存在时执行）：全新 job 跑到这一步时工具链
   还没建，`package/.../compile` 必然失败，所以先看有没有工具链，没有就明说跳过。

剔除的判定标准是报错落在 `nft_ext_fullcone.c` / `nf_nat_fullcone.c`，或补丁打不上
（`Hunk #N FAILED` / `patch does not apply`）。剔除后其余功能照常出固件，
`UNVERIFIED.txt` 标 `FullCone: 已剔除`；保留则标 `FullCone: 含 …`。

这样最坏情况不会白跑 90 分钟。第 2 轮（`506b868`）的实例：试编译被跳过、静态自检通过，
四件套在正式编译里全部编过——所以「预编失败」的告警曾经是误报，已在上面的改法里消掉。

## 怎么跑

两种方式，跑的是同一份工作流、同一套产物：

1. **自动**：push 到 `main`，改动命中 `ppe/**` 或 `.github/workflows/build-ppe.yml` 即触发。
   两个输入取文件里钉住的默认值（`ppe_sha`=7d65a3e、`tiny_sha`=57e4ff3）。
2. **手动**：Actions → **Build AX6 PPE-NSS Firmware** → Run workflow。
   两个输入都留空即用默认钉住的 commit。

> 2026-11-28 起加了 push 触发（带 `paths` 过滤）。此前本线与 LibWrt 线都是纯手动，
> 只有主线 `build.yml` 挂 push。主线 `paths` 不含 `ppe/**`，两线不会互相误触发。
> `concurrency` 为 `ax6-ppe-${{ github.ref }}`、`cancel-in-progress: false`：
> 连续推送时后一轮排队等前一轮跑完，不会把正在编的那轮杀掉。
> push 触发下 `inputs` 是空串，`env` 里已用 `|| 默认 sha` 兜底，改动时别把 fallback 删掉。

首轮 ccache 与 dl 都空，60–100 分钟。产物在 `out/`：

```
AX6-ppe-nss-factory.ubi
AX6-ppe-nss-sysupgrade.bin
AX6-ppe-nss.manifest
AX6-ppe-nss-IMAGE-AUDIT.md     ← 体积 gate 结果
build.config
SHA256SUMS
```

### 首个跑通的产物：PPE #2 校验记录（2026-11-25）

第一次完整跑通：run #2（id `45543931799`，commit `506b868`），12:01 触发、13:14 结束，
编译步 62 分钟（ccache 与 dl 都命中）。产物 `ax6-ppe-nss-45543931799.zip`（67.5 MB）。
下面是下载后本地复核的结果，不是 CI 自述。

**哈希**（与包内 `SHA256SUMS` 逐字节比对一致）

| 镜像 | 字节 | SHA256 |
|---|---|---|
| `AX6-ppe-nss-factory.ubi` | 36,962,304 | `01c613b7beb3ee756548bf9d97f66ffa4bc6507820d108f277b5eae5679ac848` |
| `AX6-ppe-nss-sysupgrade.bin` | 35,399,946 | `d647f93f9b3a5ff61b8d9499e2a6b19f865d52fe251c07007c1068b93043c00c` |

**结构校验**：解包后把两个镜像改名成 `redmi_ax6-stock-{factory.ubi,sysupgrade.bin}`
（脚本按文件名断言），再复跑本仓库的校验器：

```sh
python3 ppe/scripts/check-stock-image.py redmi_ax6-stock-sysupgrade.bin redmi_ax6-stock-factory.ubi
```

结果 **PASS**：

- factory 35.25 MiB，282 × 128 KiB 抹除块，每块 EC 头 `UBI#` 与 VID 头 `UBI!` 都在，卷 0/1 齐
- sysupgrade 33.76 MiB，tar 内含 `kernel`(5.70 MiB) / `root`(28.06 MiB，squashfs) / `CONTROL`
- 距 64 MiB 硬门余量 28 MiB。按 818 LEB × 126,976 B 折算：kernel 占 47 LEB、rootfs 占 232 LEB，
  overlay 还能用约 539 LEB ≈ 65 MiB

**目标匹配**：`CONTROL` 为 `BOARD=redmi_ax6-stock`；内核 FIT（魔数 `d00dfeed`）的 DTB
compatible 含 `redmi,ax6-stock`，不含 `xiaomi,ax3600`。刷在单卷 stock 布局的机器上才会被接受。

**关键包**（manifest 共 237 条，节选）

| 包 | 版本 | 说明 |
|---|---|---|
| `kmod-nft-fullcone` | 6.18.60.2023.05.17~07d93b62-r4 | 源码钉在 `07d93b6` |
| `nftables-json` | 1.1.7-r1 | 带 fullcone 表达式补丁 |
| `libnftnl11` | 1.3.2-r1 | 带 `expr/fullcone.c`，`PKG_FIXUP:=autoreconf` |
| `firewall4` | 2026.10.29~e6f600c4-r1 | 依赖里已加 `kmod-nft-fullcone` |
| `luci-app-fullcone` | 0 | 默认关闭，需手动开 |
| `luci-app-homeproxy` | 0 | 代理前端 |
| `sing-box-tiny` | 1.14.0-r1 | 无 QUIC / gVisor |
| `kmod-nft-tproxy` | 6.18.60-r1 | HomeProxy 透明代理 |
| `kmod-nss-wifi-drv` | 6.18.60-r1 | NSS WiFi；本线无 ECM |
| `ttyd` / `luci-app-ttyd` | 1.7.7-r1 / 26.328 | |
| `adblock-fast` | 1.2.4-r4 | |
| `luci-theme-argon` | 3.1.4-r20261113 | |

**两处已知瑕疵**

- `luci-app-fullcone`、`luci-app-homeproxy`、`luci-i18n-homeproxy-zh-cn`、
  `luci-i18n-argon-config-zh-cn` 的 apk 版本号是 `0`：这几个包的 Makefile 自己不写
  `PKG_VERSION`（`luci-app-fullcone` 与上游 `luci-app-homeproxy` 都是这样），版本由
  `luci.mk` 兜底，apk 装了能跑，只是以后从仓库升级时版本比较会失真。
- FullCone 装上了但配置默认关闭，规则里不会出现 fullcone 表达式。

## 2026-11-28 修订（真机自检后的一版）

第一版固件在 AX6 上跑完一轮全模块自检（底座/DNS/Web/无线/PPE/防火墙/PPPoE 全过），
其余问题归为五类，这一版逐条修。**改动只落在本地文件，未推送、未编译。**

### 1. ttyd 启动即崩 → libwebsockets 钉回 4.3.3

设备实测：

```
elops_init_pt_uv: Using foreign event loop...
Listening on port: 7681
lws_context_destroy: initiated          ← 9 ms 后
procd: incarnation 23, exit_code 0
```

**第一次尝试（失败，已废弃）**：把 ttyd 依赖从 `+libwebsockets-full` 改成
`+libwebsockets-openssl`，想靠去掉 `LWS_WITH_LIBUV` 避免"抢事件循环"。
这条路根本走不通 —— ttyd 1.7.7 的 `CMakeLists.txt:64` **硬性要求** LWS_WITH_LIBUV：

```
CMake Error at CMakeLists.txt:64 (message):
  libwebsockets was not build with libuv support (-DLWS_WITH_LIBUV=ON)
ERROR: package/feeds/packages/ttyd failed to build.
```

而且 ttyd 最新版就是 1.7.7（2024-03-30），**不存在可升的 1.7.8 / 1.7.9**。

**真正的原因在 lws 版本**：这条线跟 openwrt master，feeds 里是 libwebsockets **5.1.0**。
5.x 重写了 external event loop 的实现，与 ttyd 1.7.7 的 uvwasi 主循环不兼容，
于是起动 9 ms 后 `lws_context_destroy`、退出码 0，procd 无限重拉。
**OpenWrt 24.10 稳定版用的是 lws 4.3.3 + ttyd 1.7.7 + `libwebsockets-full`**，
社区大范围验证可用 —— 这是钉版的依据。

**改法**：

- 新增 `ppe/pkgs/libwebsockets/Makefile`（取自 openwrt-24.10，4.3.3；
  修正了上游 `-DISABLE_WERROR=ON` 少一个 D 的笔误）
- `prepare.sh` 在 `feeds update` 之后、`feeds install` 之前用它覆盖 feeds 里的同名文件
- ttyd 依赖保持上游原样 `+libwebsockets-full`，另加兜底：若被改成 openssl 就改回 full

**CI 校验（已反向）**：`.config` 必须出现 `CONFIG_PACKAGE_libwebsockets-full=y`，
且 `feeds/packages/libs/libwebsockets/Makefile` 的 `PKG_VERSION` 必须是 4.3.3，
否则直接失败 —— 缺 LIBUV 编不过，版本错了起来就崩，两种都不能发出去。

### 2. 系统默认值 → 新增 `files/` overlay

`files/etc/uci-defaults/90-ax6-defaults`，首次启动执行一次：

| 项 | 改成 | 原来 | 为什么要改 |
|---|---|---|---|
| 时区 | `CST-8` / `Asia/Shanghai` | `GMT0` / `UTC` | 本机无 RTC，不接 WAN 时间停在固件编译时刻 |
| 日志 | `log_size=1024` + `log_file=/tmp/log/messages` | 128 KB | 跑一两天就把开机记录滚光，查问题没依据 |
| 内网域名 | `dhcp.lan.domain='lan'` | 未设置 | `hostname.lan` 解析成 NXDOMAIN |
| FullCone | `firewall.@defaults[0].fullcone='1'` | 默认 0 | 四件套编进去了但开关没开，等于白装 |
| homeproxy | 未启用时删掉 3 个 firewall include | 留着 | 每次 fw4 reload 刷三条 `unreachable path` warning |

**恢复 homeproxy include**（以后真要启用代理时手工加回，否则透明代理不生效）：

```sh
uci add firewall include
uci set firewall.@include[-1].name='homeproxy_forward'
uci set firewall.@include[-1].path='/var/run/homeproxy/fw4_forward.nft'
uci set firewall.@include[-1].type='nftables'
# 另两条同理：homeproxy_input → fw4_input.nft，homeproxy_post → fw4_post.nft
uci commit firewall
```

### 3. 崩溃现场 → 补 pstore / ramoops

设备树早就给 ramoops 留了 1 MiB（`ramoops@51200000`, nomap non-reusable），
但第一版内核没编 pstore：`/sys/fs/pstore` 不存在，`/proc/kallsyms` 里 pstore 符号为 0。
异常重启、oops、panic 全都抓不到现场。

加 `CONFIG_PACKAGE_kmod-ramoops=y`（依赖自动拉 `kmod-pstore` + `kmod-reed-solomon`，
KCONFIG 带 `CONFIG_PSTORE` / `_CONSOLE` / `_RAM`）。

归档不用自己写：base-files 自带 `/etc/init.d/pstore-archive`，启动时挂 pstore →
转存到 `/root/pstore/<时间>-<boot_id>/` → 清空 → 保留 20 份。
v2 里额外写的 `files/etc/rc.local` 与之重复（路径还不一致，写的是 `/etc/pstore-archive`），
且 `rm -f /sys/fs/pstore/*` 有抢先删掉现场的风险，v4 已删除。

### 4. 补三个命令行工具

`iperf3` / `tcpdump` / `openssl-util`，合计约 1 MiB。
理由：换机现场恰恰没网，`apk add` 装不了，而压测吞吐、抓包定位、手工签证书都要用这些。

### 5. `prepare.sh` 加 7/7 步

把 `../ppe/files/` 复制到源码树 `files/`，并 `chmod 755` 补回 Windows 检出丢掉的可执行位
（否则 `uci-defaults` 不会执行，改了等于没改）。当前 `files/` 里只有
`etc/uci-defaults/90-ax6-defaults` 一个文件。

### 这一版**没**动的

- `luci-app-fullcone` 版本号仍是 `0`（见下文「两处已知瑕疵」），不影响运行。
- 无线默认仍保持官方行为：`radio0/radio1` 上电、两个 iface `disabled=1`。不预置 SSID。
- DHCP 是否开启、LAN 地址，都不在固件里预置，由阶段四/五按现场配置。

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
