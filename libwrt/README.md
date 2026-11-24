# libwrt 平行分支（LibWrt 25.12-nss）

这里放的是**第二条编译路线**，与仓库主线（qosmio/openwrt-ipq `25.12-nss`，内核 6.12.91）并列，
互不影响：主线的 `.github/workflows/build.yml` 照旧按 push 触发，本目录对应的
`.github/workflows/build-libwrt.yml` **只允许手动触发**。

## 为什么另起一条

| 项 | 主线 qosmio | 本分支 LibWrt | 当前在跑的系统 |
|---|---|---|---|
| 内核 | 6.12.91 | **6.12.116** | 6.12.40 |
| 架构 | NSS/ECM | NSS/ECM（同） | NSS/ECM |
| `redmi_ax6-stock` | 需自己打补丁 | **树内原生** | — |
| luci feed | 手动换 immortalwrt | **本来就是 immortalwrt 25.12** | — |
| golang | 依赖 feed 自带 1.27 | 同 | — |
| `px5g-openssl` | 树里没有，要改依赖 | **树内有** | — |

也就是说：主线里那三处 workaround（换 luci、Go 版本、px5g 死依赖）在这条线上**根本不需要**。
少三个可变因素，就少三个失败点。

代价是 LibWrt 是单一维护者的中文分支（分支 `25.12-nss`，2026-11-21 有提交），
NSS 补丁来自 JiaY-shi + qosmio，成熟度不如 qosmio 主线久经使用。

## 怎么用

1. 仓库 Actions → 左侧 **Build AX6 LibWrt NSS Firmware** → Run workflow
2. `source_ref` 留空即用 `25.12-nss`
3. 产物 artifact：`ax6-libwrt-firmware`（含 sysupgrade.bin / manifest / config.buildinfo / sha256sums）

首轮 ccache 是空的（key 前缀 `ccache-libwrt2512-`），预计 60–100 分钟；dl 缓存首轮也要全量下载。

## 配置文件的来源（重要）

`configs/libwrt-ax6.config` = **massivehard2014/ax6-nss-pure 的 NSS 核心段（作者已在 LibWrt 上编过）
+ 我们从当前系统 371 个 `=y` 里筛出的用户可见包**。

没有把整份 `ax6.config` 搬过来，原因是：那 371 个符号是按 qosmio 树生成的，
其中一部分（如 `CONFIG_NSS_*`、`kmod-qca-nss-drv-64`）在 LibWrt 里不存在或语义不同，
`make defconfig` 会静默丢弃，搬过来只会制造"以为配了其实没配"的假象。

## 编译时的三道校验

1. **应用配置后**：`redmi_ax6-stock=y` 必须存在，`NSS_MEM_PROFILE` 必须是 MEDIUM（本机 392 MiB）
2. **核心审计（失败即中止）**：ssdk / nss-dp / nss-drv / nss-ecm / nss-firmware-ipq807x /
   wireguard 四件套 / tailscale / kmod-tun / luci-base
3. **增强审计（只告警并写入 job summary）**：pppoe offload、nss-ifb、fullcone、nathelper、
   argon、openclash、mosdns、turboacc、vlmcsd、cpufreq、ddns、wol、upnp、sqm-nss、ntfs3 …
   以及 `CONFIG_MAC80211_NSS_SUPPORT`（WiFi 是否走 NSS）

**第三道是重点**：它把"哪些包被 defconfig 吃掉了"直接列进 Actions 的 Summary，
不用等刷完机才发现界面少了一块。

## 刷机与验收（刷之前先读）

刷的是 `redmi_ax6-stock` 变体，与本机 `board_name = redmi,ax6-stock` 一致，可直接 sysupgrade。
**刷之前先做备份**：`sysupgrade -b` 只含配置，ART / U-Boot / 整片 NAND 另备。

NSS 是否真的在加速，按这四条看，缺一不可：

```sh
lsmod | grep -E 'qca_nss|ecm|ssdk'
sysupgrade -b /tmp/backup-$(date +%F).tar.gz   # 刷前

# 刷后：
cat /sys/kernel/debug/ecm/ecm_db/connection_count        # 跑流量时应增长
ecm_dump.sh | grep 'accel_mode' | head                   # 出现 accel_mode=2 才算硬件加速
cat /proc/sys/net/netfilter/nf_conntrack_count           # 只是参考，NOT 判据
```

判据说明（来自 llz121517 的实测，比常见说法准确）：

- **必须** `accelerated_count > 0` **且** `accel_mode=2`
- **不要**用 `nf_conntrack` 的 `HW_OFFLOAD` 标记判断 —— qca-nss-ecm 不走 `nf_flow_table`，那个标记永远是 0
- `nft list ruleset | grep -c fullcone` 有输出才说明 fullcone 规则真生效
- **flow offloading 必须为 0**：本仓库已在首启脚本 `99-nss-offload` 里写死，别在 LuCI 里再打开

## 已知风险

| 风险 | 说明 |
|---|---|
| LibWrt 单维护者 | 分支只有一个，上游若停更只能回主线 |
| 第三方包目录重复 | 并入了 TerryLip 的 `package/new`+`emortal`，与 immortalwrt feed 里同名包（argon 等）可能重复定义；编译日志里出现 duplicate 警告属预期，不阻断 |
| 符号不存在 | 见第三道审计；被丢弃的包按 Summary 补 |
| WiFi 走 NSS | `MAC80211_NSS_SUPPORT` 若未生效，WiFi 仍可用但走主机 CPU，不影响上网 |
| 与现有 openclash 配置 | 刷入后 `/etc` 保留则配置在，但已装软件包不保留，需 `apk add` 补 |

## 回滚

主线固件（qosmio 版）仍在本仓库 Releases/Actions 产物里；
系统层面回滚靠刷前那份 `sysupgrade -b` + NAND 整片备份。
