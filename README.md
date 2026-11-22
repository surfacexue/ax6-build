# AX6 NSS 固件（启用 WireGuard）云编译

用 GitHub Actions 编译 Redmi AX6（`redmi_ax6-stock`，单 UBI 大分区）的 NSS 固件，
源码来自 [TerryLip/AX6NSS-qosmio](https://github.com/TerryLip/AX6NSS-qosmio)，
`ax6.config` 取自作者的 `AX6.config`，**只改了 4 行**：把 WireGuard 相关包从关闭改为启用。

## 相对上游的改动

```diff
-# CONFIG_PACKAGE_kmod-wireguard is not set
+CONFIG_PACKAGE_kmod-wireguard=y
-# CONFIG_PACKAGE_wireguard-tools is not set
+CONFIG_PACKAGE_wireguard-tools=y
-# CONFIG_PACKAGE_luci-proto-wireguard is not set
+CONFIG_PACKAGE_luci-proto-wireguard=y
-# CONFIG_PACKAGE_rpcd-mod-wireguard is not set
+CONFIG_PACKAGE_rpcd-mod-wireguard=y
```

其余 8000+ 行与作者 `AX6.config` 逐字节一致，NSS / ECM 硬件加速、目标设备均未改动。

## 怎么用

1. 仓库 **Actions** 页 → 左侧 **Build AX6 NSS Firmware** → 右侧 **Run workflow** → 再点绿色按钮
2. 等待编译（公共仓库 4 核 runner，预计 2–4 小时，上限 6 小时）
3. 完成后在本页 **Artifacts** 下载 `ax6-nss-wireguard-firmware`
4. 解压得到 `*sysupgrade.bin` 与 `sha256sums`

## 文件说明

| 文件 | 用途 |
|---|---|
| `ax6.config` | 编译配置（作者 `AX6.config` + 4 行 WireGuard） |
| `.github/workflows/build.yml` | 云编译流程 |

编译流程跟随作者 README 的“本地编译详细步骤”，但有两处**必须偏离**（2026-11-22 实测修正）：

- `luci-base`、`luci-mod-status` ← 用 `git clone --sparse` + `git sparse-checkout`
  从 `immortalwrt/luci` 的 `master` 分支取。**原 README 的 `svn export` 已失效**：
  GitHub 2024 年停止 Subversion 支持，`https://github.com/immortalwrt/luci/trunk` 返回 404
- `golang` ← 换成 `sbwml/packages_lang_golang` 的 `23.x` 分支（`git clone`，这一步原本就正常）

删包方面只删 `coremark`（未被配置启用，删除无害）。**`v2ray-geodata` 不删**：
`ax6.config` 里 `CONFIG_PACKAGE_v2ray-geoip=y`、`v2ray-geosite=y` 正是该包提供，
且 openclash 依赖它们，删掉会断依赖链导致 `depends on v2ray-geoip which is not available`。

因采用“原位替换”，`package/feeds/` 下的软链保持有效，**不要**再重跑
`./scripts/feeds install -a`（会因 coremark 已删而报缺包）。

## 注意

`make menuconfig` 在 CI 里无法交互，已用等价的 `make defconfig` 代替。
