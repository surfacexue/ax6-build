# GitHub 云编译使用手册（红米 AX6 / NSS 固件）

适用仓库：`surfacexue/ax6-build`
固件源码：`TerryLip/AX6NSS-qosmio`，分支 `qualcommax-6.x-nss-wifi`
目标设备：`qualcommax/ipq807x` → `redmi_ax6-stock`（aarch64_cortex-a53，内核 6.12.31）
文档版本：2026-11-24 17:40

---

## 0. 速查

| 要做的事 | 命令 / 入口 |
| --- | --- |
| 触发编译 | 推 main，且改动命中 `ax6.config` 或 `.github/workflows/build.yml` |
| 只想强制重编 | 改一行 `.github/workflows/build.yml` 的注释或 bump `# trigger-marker`，再推 |
| 网页手动触发 | Actions → Build AX6 NSS Firmware → Run workflow（可填 `source_ref`） |
| 看进度 | `curl -s "https://api.github.com/repos/surfacexue/ax6-build/actions/runs?per_page=3"` |
| 看某轮每步 | `curl -s ".../actions/runs/<run_id>/jobs"` |
| 拿固件 | run 页面底部 Artifacts → `ax6-nss-wireguard-firmware.zip` |
| 看失败日志 | `https://raw.githubusercontent.com/surfacexue/ax6-build/logs/failure-<run_id>.txt` |
| 本机 curl 加参数 | `--ssl-no-revoke --noproxy '*'`（否则 schannel 报 0x80092012） |

---

## 1. GitHub 云编译是怎么被触发的

GitHub **不会**自动帮你编译任何东西。它只认仓库里的一份文件：

```
<仓库根>/.github/workflows/<任意名字>.yml
```

没有这个文件（或文件不在默认分支），这个仓库在 GitHub 眼里就没有工作流，Actions 页面是空的，推任何代码都不会编译。

有文件之后，**跑不跑**由文件里面的 `on:` 决定，**跑什么**由 `jobs:` 决定。本仓库的 `on:` 是这样：

```yaml
on:
  push:
    branches: [main]              # 只认 main 分支
    paths:                        # 且必须改动下面两个文件之一
      - 'ax6.config'
      - '.github/workflows/build.yml'
  workflow_dispatch:              # 允许在网页上手动点
    inputs:
      source_ref: { ... }
```

所以：**"别的仓库推送不编译" 是正常现象** —— 那些仓库要么没有 workflow 文件，要么有但 `on:` 不匹配。

> `on:` 的全部写法（`push` / `paths` / `branches` / `workflow_dispatch` / `schedule` …）官方说明：<https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows>

### 1.1 推送了却不编译，按这个表排查

| 可能原因 | 怎么确认 | 怎么修 |
| --- | --- | --- |
| 仓库里没有 workflow 文件 | 看 `.github/workflows/` 是否存在、有无 `.yml` | 加一份 |
| 有文件但 `on.branches` 不含你推的分支 | 看文件里的 `on:` | 改 `branches` 或用 main |
| 有 `paths` 过滤，但你改的文件不在列表里 | 看提交里改了哪些文件 | 改 `paths`，或改动列表里的文件 |
| Actions 被关掉了 | 仓库 Settings → Actions → General；或 Actions 页提示 `Workflows aren't being run on this repository` | 打开 Actions 权限 |
| 提交是用 `GITHUB_TOKEN` 推的 | 看推送方是谁；这是 GitHub 的防递归机制 | 用 SSH / PAT / App token 推 |
| 提交信息里有 `[skip ci]`、`[ci skip]`、`***NO_CI***` | 看 commit message | 去掉 |
| 是 fork，且首次运行需维护者批准 | Actions 页会显示等待批准 | 点批准 / 在 fork 里启用 |
| 私有仓库免费额度用尽 | Settings → Billing | 充值或转公开仓库（公开仓库 Actions 不计费） |
| workflow 文件不在**默认分支** | `workflow_dispatch` 只从默认分支读 | 合并到默认分支 |

本仓库对号入座：文件是 `.github/workflows/build.yml`，在 default 分支 `main` 上，`permissions: contents: write`（因为失败日志要推到 `logs` 分支），Actions 已启用，所以"推 main + 改那两个文件"就会跑。

> 顺带一条常被忽略的：**用 `GITHUB_TOKEN` 推的提交不会再触发新的 workflow**。这就是为什么工作流里往 `logs` 分支推失败日志不会引起递归编译。

---

## 2. 触发本仓库编译

### 2.1 推送触发（主要方式）

```bash
git add ax6.config .github/workflows/build.yml
git commit -m "chore: ..."
git push origin main
```

- 只改这两个文件才算数。改 README、改别的文件不触发。
- 空提交不触发（`paths` 过滤要求真有文件被改动）。
- `concurrency` 配了 `cancel-in-progress: true`：**编译期间再推 main 会直接取消在跑的那轮**。要改脚本先等结果。
- 想强制重编又不想动配置：把文件头的 `# trigger-marker: N` 加一即可，这是我们一直在用的做法。

`branches` / `paths` 的匹配规则（含 `!` 取反、通配符）见 <https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows>

### 2.2 手动触发

Actions → `Build AX6 NSS Firmware` → `Run workflow`。

- `source_ref` 可指定源码分支/标签，默认 `qualcommax-6.x-nss-wifi`。
- 手动触发与推送触发跑的是同一份工作流，产物一样。

### 2.3 重跑某一轮

run 页面右上 `Re-run all jobs`。**这个按钮需要 GitHub 登录态或 API token**；本机没有 PAT，所以目前等价做法是推一版（改注释或 bump trigger-marker）。

---

## 3. 云编译环境怎么配

一句话：**runner 是 GitHub 给的一台干净 Ubuntu 虚拟机，编译目标由 `ax6.config` 决定，不由 runner 决定。** 交叉编译，x86_64 的 runner 编出 arm64 的固件。

### 3.1 runner（机器本身）

```yaml
runs-on: ubuntu-22.04
timeout-minutes: 350     # GitHub 单 job 上限 6 小时，留 10 分钟余量
```

- 换机器只改这一行：`ubuntu-22.04` / `ubuntu-24.04` / `ubuntu-latest` / `self-hosted`。
- 合法标签与机器规格（几个 vCPU、多少内存、多大磁盘）以官方表为准：<https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners>
- 本仓库钉 22.04，因为 OpenWrt 的构建依赖（`python3-distutils`、旧版 gcc 兼容性）在 22.04 上最稳；24.04 去掉了 `python3-distutils`，要另装。
- runner 规格：4 vCPU / 16 GB 内存 / 根分区约 14 GB。所以下面才要腾磁盘。

### 3.2 磁盘布局（不然会顶满）

```yaml
env:
  CCACHE_DIR: /mnt/ax6build/openwrt/.ccache
```

- runner 有一块 **74 GB 临时盘挂在 `/mnt`**，根分区只有约 14 GB（清理后约 30 GB）。
- 步骤 4 删掉 runner 预装的 dotnet / android / ghc / CodeQL / boost 等腾空间。
- 步骤 6 把源码 clone 到 `/mnt/ax6build/openwrt`，再软链成工作目录下的 `./openwrt`。

### 3.3 目标平台（关键：由 `.config` 决定）

`ax6.config` 是整份 OpenWrt `.config`，编译前直接覆盖源码树的 `.config`。目标平台写在三级符号里：

```
CONFIG_TARGET_qualcommax=y                                          # 第 38 行：目标板
CONFIG_TARGET_qualcommax_ipq807x=y                                  # 第 53 行：子目标
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6-stock=y           # 第 81 行：设备
CONFIG_TARGET_BOARD="qualcommax"                                    # 第 97 行
CONFIG_TARGET_SUBTARGET="ipq807x"                                   # 第 98 行
CONFIG_TARGET_ARCH_PACKAGES="aarch64_cortex-a53"                    # 第 100 行
```

- **换设备 = 改这里**，不是改 workflow。设备变了，架构、内核版本、`DEVICE_PACKAGES`、`ipq-wifi-*` 固件包都跟着变。
- 换 target 时还要同步改 **第 10 步的硬校验**，那里写死了设备名：
  ```bash
  grep -E '^CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6-stock=y' .config
  ```
  不改就会在"应用编译配置"这一步报 `目标设备 redmi_ax6-stock 未启用`。
- `make defconfig` 会补全依赖、**同时会静默丢掉依赖不满足的符号**。换目标后别拿旧 `.config` 硬套，按新目标重新生成再比对。

#### 这些符号名从哪来（不是手写格式，是构建系统生成的）

命名规则固定为三级：

```
CONFIG_TARGET_<board>
CONFIG_TARGET_<board>_<subtarget>
CONFIG_TARGET_<board>_<subtarget>_DEVICE_<device>
```

- `<board>` / `<subtarget>` 来自源码树 `target/linux/<board>/<subtarget>/target.mk` 是否存在。
- `<device>` 来自该子目标镜像目录里的 `TARGET_DEVICES` 列表。本树就是
  `target/linux/qualcommax/image/ipq807x.mk`：第 384 行 `define Device/redmi_ax6-stock`，第 393 行 `TARGET_DEVICES += redmi_ax6-stock`。
- `CONFIG_TARGET_BOARD` / `CONFIG_TARGET_SUBTARGET` / `CONFIG_TARGET_ARCH_PACKAGES` 三行是 `make defconfig` 按 target 自动填的派生值，不用手写。

查任意设备的目标名，三种办法：

1. 源码树里 `make menuconfig` → Target System / Subtarget / Target Profile，选完看 `.config`；
2. `make defconfig` 之后看 `tmp/.targetinfo`；
3. 直接 grep：`grep -rn "define Device/" target/linux/<board>/<subtarget>/image/`。

写错一个字符的后果：第 10 步直接失败（硬校验），或者 `make defconfig` 把整行静默丢掉，编出来的固件给错设备。

### 3.4 源码（编哪棵树）

```yaml
env:
  SOURCE_REF: ${{ github.event.inputs.source_ref || 'qualcommax-6.x-nss-wifi' }}
```

步骤 6：

```bash
git clone --depth 1 --branch "$SOURCE_REF" \
  https://github.com/TerryLip/AX6NSS-qosmio.git /mnt/ax6build/openwrt
```

- 换源码仓库 → 改这一行的 URL。
- `--depth 1` 只拉一层，快，但也意味着拿不到历史；要对比版本得另 clone。
- 每次都是分支最新，不钉 commit。上游一动，同样的提交编出来的东西就可能变。

### 3.5 构建依赖（runner 上没有的得装）

步骤 5：

```bash
sudo apt-get install -y \
  build-essential clang flex bison g++ gawk \
  gcc-multilib g++-multilib gettext git \
  libncurses5-dev libssl-dev python3-distutils \
  rsync unzip zlib1g-dev file wget subversion ccache time
```

交叉工具链（aarch64-openwrt-linux-musl-gcc 等）**不用手装**，由 OpenWrt 在编译过程中自己构建。

### 3.6 关键环境变量

| 变量 | 值 | 谁在用 | 改了会怎样 |
| --- | --- | --- | --- |
| `SOURCE_REF` | `qualcommax-6.x-nss-wifi` | 步骤 6 clone | 换源码分支 |
| `CCACHE_DIR` | `/mnt/ax6build/openwrt/.ccache` | ccache / actions-cache | 必须与 `rules.mk` 第 355 行的落盘位置一致，否则缓存白传 |
| `GOTOOLCHAIN` | `local`（由 `golang-package.mk` 设） | go 构建 | 改 auto 会引入不确定性，别动 |
| `CCACHE_NOCOMPRESS` | `true`（由 `rules.mk` 第 353 行强制） | ccache | 缓存不压缩，所以要给 `--max-size` 上限 |

### 3.7 权限与并发

```yaml
permissions:
  contents: write          # 失败时把日志推到 logs 分支
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true # 同分支新推送取消旧任务
```

`permissions` / `concurrency` / `timeout-minutes` / `env` / `steps` 的字段定义，全部在这一页：
<https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions>
`${{ github.* }}` 这类表达式能用哪些字段（`github.run_id`、`github.token`、`github.event.inputs.*` …）：
<https://docs.github.com/en/actions/learn-github-actions/contexts>

### 3.8 缓存

```yaml
- uses: actions/cache@v4
  with:
    path: /mnt/ax6build/openwrt/.ccache
    key: ccache-${{ github.run_id }}      # 每轮新 key（总是保存）
    restore-keys: ccache-                 # 前缀匹配，取最近一份恢复
```

配合步骤 8 开头的 `ccache --max-size=4G`（放在恢复之后执行，避免被缓存里的旧 `ccache.conf` 覆盖）。

**缓存的粒度：路径级、整包。** `actions/cache` 把 `path` 命中的内容打成一个归档上传、恢复时整包解开，没有文件级增量比对；想只缓存某个子目录，必须把它逐条写进 `path`。本仓库目前**只有 ccache 这一处缓存**。

**为什么 `staging_dir` 不能单独缓存**：决定「这个包要不要重编」的是 `build_dir` 里的 stamp 文件，不是 `staging_dir` 里有没有装好的库。源码树 `include/package.mk`：

```
PKG_BUILD_DIR    = $(BUILD_DIR)/<pkg>-<version>
STAMP_PREPARED   = $(PKG_BUILD_DIR)/.prepared_<Makefile 与依赖的 md5>_<config 变量>
STAMP_CONFIGURED = $(PKG_BUILD_DIR)/.configured_<PKG_CONFIG_DEPENDS 的取值>
STAMP_BUILT      = $(PKG_BUILD_DIR)/.built
```

`staging_dir` 只是安装目的地，唯一的例外是宿主包的安装戳 `staging_dir/host/stamp/.<pkg>_installed`，而它又依赖 `build_dir/host/<pkg>/.built`。所以只恢复 `staging_dir` 的话，`make` 照样从头 configure + compile，再把刚解开的文件覆盖一遍——代价付了、时间没省。真要缓存构建状态，必须 `build_dir` + `staging_dir` 成对缓存，而 `build_dir` 对 ipq807x 全量镜像是十几 GB 量级，超仓库 10 GB 缓存配额，且必须用「源码 commit + feeds 引用 + `ax6.config` 哈希」做精确 key（命中精确 key 时 `actions/cache` 跳过保存，不会每轮新增一份）。

**第二处缓存（步骤 12）：`dl/`** —— 2026-11-24 加，与 ccache 分开存，因为两者的可变性相反（ccache 每轮都在长，`dl/` 只在仓库状态变化时长）。

```yaml
- name: 恢复 dl 缓存            # 步骤 12，必须排在「下载依赖源码」之前
  uses: actions/cache@v4
  with:
    path: /mnt/ax6build/openwrt/dl
    key: dl-${{ hashFiles('ax6.config') }}-${{ hashFiles('.github/workflows/build.yml') }}
    restore-keys: |
      dl-
```

- 为什么 `dl/` 安全：`make download` 按 `PKG_SOURCE` 的文件名往里放 tarball，它只是原料，不参与「要不要重编」的判定；陈旧也只会影响它自己那一包，不会像 `staging_dir` 那样让别的包链到错的库。
- 为什么用**精确 key** 而不是 `run_id`：`dl/` 在仓库状态不变时内容不变，用内容哈希做 key，第二、三轮直接命中精确 key，`actions/cache` 据此**跳过保存**，不会每轮新增一份归档（否则 10 GB 仓库配额迟早吃穿）。
- `restore-keys: dl-` 是保底：改了 `ax6.config` 或 workflow 后 key 变了，仍按前缀捞回上一份 tarball，`make download` 只补缺的那几个。
- 唯一要留意的风险：某一轮 `make download` 中途失败，`dl/` 里可能留下不完整的文件并被存进缓存。OpenWrt 对声明了 `PKG_MIRROR_HASH` 的包会校验，其余只查存在性——极端情况下下一轮可能带着坏包编不过。真遇到就删掉缓存条目重跑一次。

体积是实测项：步骤 18（收集产物）会打印 `du -sh openwrt/.ccache openwrt/dl` 与 `dl` 文件数，每轮日志里都有。

### 3.9 想改环境时，改哪里

| 想改的东西 | 改哪个文件的哪一处 |
| --- | --- |
| 机器规格 / 系统 | `runs-on`、`timeout-minutes` |
| 目标设备、内核、架构 | `ax6.config` 的 `CONFIG_TARGET_*` + 第 10 步的硬校验 |
| 源码仓库 / 分支 | 第 6 步的 clone URL、`SOURCE_REF` |
| 多加软件包 | `ax6.config`（一次加一类） |
| 缓存策略 | 步骤 7 的 ccache `path` / `key`、步骤 8 的 `--max-size`、步骤 12 的 dl 缓存 `key` |
| 失败时的诊断内容 | 步骤 15 的 grep 正则、步骤 16 的报告模板 |

### 3.10 编译环境到底是谁搭的

**GitHub 只做两件事：给一台干净的 `ubuntu-22.04` 虚拟机，然后逐条执行 workflow 里的命令。它不读 `.config`，也不会按 config 预装任何东西。**

真正的编译环境是在 `make` 里由 **OpenWrt 构建系统自己造出来的**，分六层：

| 层 | 谁负责 | 落在哪 |
| --- | --- | --- |
| 1. 虚拟机与操作系统 | GitHub（`runs-on`） | 全新 ubuntu-22.04，预装常见工具，**不含任何交叉工具链** |
| 2. 宿主软件包 | 工作流步骤 5（apt） | clang / gcc-multilib / ncurses / rsync / ccache … |
| 3. 宿主工具 | OpenWrt 在 `make` 中自建 | `staging_dir/host`、`staging_dir/hostpkg` |
| 4. 交叉工具链 | OpenWrt 在 `make` 中自建 | `staging_dir/toolchain-aarch64_cortex-a53_gcc-14.3.0_musl`（含 `aarch64-openwrt-linux-musl-gcc`） |
| 5. 目标 staging | OpenWrt 在 `make` 中自建 | `staging_dir/target-aarch64_cortex-a53_musl`（目标架构的库与头文件） |
| 6. 镜像 | OpenWrt 在 `make` 中自建 | `bin/targets/qualcommax/ipq807x/` → squashfs + ubi → `sysupgrade.bin` |

`.config` 的作用是**间接的**：它告诉 OpenWrt"目标是谁、要哪些包"，OpenWrt 据此决定建哪一套工具链（架构、libc、`-mcpu=cortex-a53` 之类的参数都在里面）、编哪些包。第 10 步的 `make defconfig` 就是 Kconfig 解析：读 `ax6.config`，补全依赖，生成完整的 `.config` 和 `tmp/.targetinfo`。

所以耗时结构是这样的：步骤 1–13 加起来约 12 分钟，全是"准备"；真正的大头在第 14 步（冷缓存 83 分钟、ccache 命中后 63 分钟）—— 第一次 `make` 要先构建 host 工具与交叉工具链，然后才逐包编译。上面那张表里的第 4 行路径，就是上一轮失败日志里能直接看到的证据。

> 另一条路（本仓库没用）：OpenWrt 官方提供 `openwrt/imagebuilder`、SDK 的 Docker 镜像，可以把工具链与环境预打包，省掉每次重建。代价是要自己维护镜像，并要求镜像与源码树版本匹配。

---

## 4. 一轮跑什么（19 步）

GitHub 把 runner 注入的 `Set up job` 算第 1 步，所以页面上的编号比 yml 里的 `- name:` 多 1。

| 步 | 名称 | 职责 | 典型耗时（run #9） |
| --- | --- | --- | --- |
| 1 | Set up job | runner 注入 | 0.0 分钟 |
| 2 | 检出本仓库 | 拿到 `ax6.config` 与 workflow | 0.0 |
| 3 | 运行环境信息 | uname / nproc / free / df | 0.0 |
| 4 | 清理磁盘 | 删 dotnet、android、ghc、CodeQL 等 | 3.5 |
| 5 | 安装编译依赖 | build-essential / clang / ccache / time … | 0.3 |
| 6 | 拉取固件源码 | clone 到 `/mnt/ax6build/openwrt`，软链 `./openwrt` | 0.1 |
| 7 | 恢复 ccache | 从缓存恢复 `/mnt/ax6build/openwrt/.ccache` | 0.0～ |
| 8 | 更新 feeds | luci 换源到 `immortalwrt/luci;openwrt-25.12` + 3 道校验 + 设 ccache 上限 | 0.9 |
| 9 | 替换 golang | 换 `sbwml/packages_lang_golang` 27.x + Go 版本校验 | 0.0 |
| 10 | 应用编译配置 | `cp ax6.config openwrt/.config` + `make defconfig` + 校验目标设备 | 0.6 |
| 11 | 校验包已启用 | WireGuard 4 包 + tailscale + kmod-tun | 0.0 |
| 12 | 恢复 dl 缓存 | 从缓存恢复 `/mnt/ax6build/openwrt/dl`（tarball 原料） | 0.0～ |
| 13 | 下载依赖源码 | `make download -j8`（命中缓存后只补缺的） | 6.9 → 1 以内 |
| 14 | 编译固件 | `make -j$(nproc)`，失败后 `timeout 45m make -j1 V=s` | 62.7–82.8 |
| 15 | 失败诊断 | job summary + annotation（仅失败/取消） | — |
| 16 | 发布失败日志 | 推到 `logs` 分支（仅失败/取消） | — |
| 17 | 上传编译日志 | artifact `build-log`（仅失败/取消） | — |
| 18 | 收集产物 | 拷 sysupgrade / factory.ubi / sha256sums / manifest，并打印 `.ccache` 与 `dl` 体积 | 0.0 |
| 19 | 上传产物 | artifact `ax6-nss-wireguard-firmware` | 0.1 |

整 job 约 **74–95 分钟**（有 ccache 命中 74 分钟，冷缓存 95 分钟）。job 超时 350 分钟。

---

## 5. 看进度

### 5.1 列最近几轮

```bash
curl -sS --ssl-no-revoke --noproxy '*' \
  "https://api.github.com/repos/surfacexue/ax6-build/actions/runs?per_page=3" \
  | python -c "import json,sys; [print(r['id'], r['head_sha'][:7], r['status'], r['conclusion'], 'run#', r['run_number']) for r in json.load(sys.stdin)['workflow_runs']]"
```

### 5.2 看某一轮每个步骤

```bash
curl -sS --ssl-no-revoke --noproxy '*' \
  "https://api.github.com/repos/surfacexue/ax6-build/actions/runs/<run_id>/jobs" -o j.json
```

读 `jobs[0].steps[]` 的 `number` / `name` / `status` / `conclusion` / `started_at` / `completed_at`。定位失败在第几步，就用这个接口。

### 5.3 限制

- 匿名 API **60 次/小时**。别每分钟轮询，10 分钟一次足够（一轮 95 分钟）。
- 步骤日志（真实输出）**必须登录才能下**，公开仓库的 logs 端点也要 token。所以失败时靠 logs 分支的纯文本，不靠网页翻日志。

---

## 6. 拿产物

run 页面底部 **Artifacts** → `ax6-nss-wireguard-firmware.zip`，保留 30 天。

zip 内含：

- `*sysupgrade.bin` —— 刷机用（必须先解压，sysupgrade 只认 `.bin`）
- `*factory.ubi`
- `sha256sums`
- `config.buildinfo`
- `*.manifest` —— 已装包清单，比拆镜像快

参考尺寸：run #9 的 zip 为 **98.9 MB**（加 tailscale 前是 80.6 MB）。

---

## 7. 失败怎么查

按这个顺序，能覆盖 90% 情况：

1. **先看第几步失败**（§5.2 的 `/jobs` 接口）
   - 第 8 步 → LuCI feed / ucode 问题
   - 第 9 步 → Go 版本或 clone 失败（网络抖动也会）
   - 第 10 步 → 目标设备符号被丢
   - 第 11 步 → 包被 `make defconfig` 丢掉（依赖不满足）
   - 第 14 步 → 某个包编不过
2. **读 logs 分支的纯文本**
   ```bash
   curl -sS --ssl-no-revoke --noproxy '*' \
     "https://raw.githubusercontent.com/surfacexue/ax6-build/logs/failure-<run_id>.txt" -o f.txt
   ```
   注意：分支每次 `git push -f` 覆盖，只保留最近一次失败。
3. 关键行长这样：
   ```
   make[3]: *** [.../tailscale-1.104.6/.built] Error 1
   make[2]: *** [package/feeds/packages/tailscale/compile] Error 1
       ERROR: package/feeds/packages/tailscale failed to build.
   ```
4. `cat` 看不出东西：日志里 make 输出被折叠成超长单行。用 Python 按关键词切片：
   ```python
   t = open('f.txt', encoding='utf-8', errors='replace').read().splitlines()
   for i, l in enumerate(t):
       if 'ERROR:' in l or 'failed to build' in l:
           print(i + 1, l[-2000:])
   ```
5. 判断这个包是不是必需的：非必需就从 `ax6.config` 关掉，先拿到可用固件；必需（wireguard / tailscale）就修，别绕过。
6. 不确定时退回已知可用配置：`git revert` 到 `442bb29`（只有 WireGuard，无 tailscale），先把固件拿到手。

---

## 8. 改配置

### 8.1 加软件包

1. 只改 `ax6.config`，一次加一类包，编过再继续。
2. `make defconfig` 会静默丢弃依赖不满足的包 —— 加完看第 11 步是否仍全绿。
3. 关键行必须存在（工作流会校验）：
   ```
   CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6-stock=y
   CONFIG_PACKAGE_kmod-wireguard=y
   CONFIG_PACKAGE_wireguard-tools=y
   CONFIG_PACKAGE_luci-proto-wireguard=y
   CONFIG_PACKAGE_rpcd-mod-wireguard=y
   CONFIG_PACKAGE_kmod-tun=y
   CONFIG_PACKAGE_tailscale=y
   ```
4. **不要**为了让某个包通过而关掉这些校验步骤。

### 8.2 换目标平台（换设备 / 换芯片）

1. 改 `ax6.config` 的 `CONFIG_TARGET_*` 三级符号与 `CONFIG_TARGET_BOARD/SUBTARGET/ARCH_PACKAGES`。
2. 同步改第 10 步的硬校验设备名，否则那步直接失败。
3. 换设备注意 `DEVICE_PACKAGES`（`ipq-wifi-*` 校准包、`kmod-*`）、内核版本（`PATCHVER`）、分区布局（DTS 里的 rootfs 大小）。
4. 用新目标的 `make menuconfig` 生成基线 `.config`，再往里加包，别拿旧配置硬套。

---

## 9. 硬约束（都是踩过的）

| # | 约束 | 违反的后果 |
| --- | --- | --- |
| 1 | luci feed 必须整源换到 `immortalwrt/luci;openwrt-25.12` | `ucode-2025.05.11 breaks luci-base` 或 apk `Error 53` |
| 2 | Go 必须 ≥ 1.27（tailscale 的 `go.mod` 写死 `go 1.27.3`） | `unknown block type: tool` / `requires go >= 1.27.3` |
| 3 | 构建树必须放 `/mnt`（74G） | 根分区约 14G，qualcommax + NSS 全量编译会顶满 |
| 4 | `GOTOOLCHAIN=local` 是刻意的 | 别指望自动下载工具链，也别改 auto |
| 5 | 不要手工拷 LuCI 模块 | 约束在 feed 根部的 `luci.mk`，换模块无效 |
| 6 | `sysupgrade.bin` 在 zip 里，必须先解压 | 传 zip 上去会报错 |
| 7 | `.apk` 用 tar 打不开 | apk v3 是 ADBd 魔数 + 偏移 4 起 raw deflate |
| 8 | `wg-quick` 不存在是正常的 | OpenWrt 走 `/lib/netifd/proto/wireguard.sh` + UCI |

补充两条本机侧的：

- 这台机器 **GitHub 22 端口被封**，git 走 `ssh://git@ssh.github.com:443/<owner>/<repo>.git`。
- 访问 GitHub HTTPS 要加 `--ssl-no-revoke`，否则 schannel 抛 `0x80092012`。

---

## 10. 产物验收（不要只看绿灯）

### 10.1 验哈希

```python
import zipfile, hashlib
z = zipfile.ZipFile('ax6-nss-wireguard-firmware.zip')
print(z.read('sha256sums').decode())
for n in z.namelist():
    if n.endswith(('.bin', '.ubi')):
        print(n, hashlib.sha256(z.read(n)).hexdigest())
```

与 `sha256sums` 里的值逐字节对比。

> 不同轮的哈希**不会**相同（内核 buildid、构建时间戳）。比哈希只能验证压缩包没损坏，不能用来判断两轮内容是否一致 —— 那种情况比 `*.manifest` 与 squashfs 文件清单。

### 10.2 验内容（证明包真在镜像里）

`sysupgrade.bin` 前面是可变的 boot/kernel，squashfs 偏移不固定，用魔数 `hsqs` 定位：

```python
import zipfile
from PySquashfsImage import SquashFsImage

z = zipfile.ZipFile('ax6-nss-wireguard-firmware.zip')
d = z.read([n for n in z.namelist() if n.endswith('sysupgrade.bin')][0])
off = d.find(b'hsqs')                       # squashfs 魔数
open('root.squashfs', 'wb').write(d[off:])

img = SquashFsImage.from_file('root.squashfs')
byp = {i.path: i for i in img}
for p in ['/lib/modules/6.12.31/wireguard.ko',
          '/usr/bin/wg',
          '/lib/netifd/proto/wireguard.sh',
          '/usr/lib/rpcd/wireguard.so',
          '/usr/sbin/tailscaled',
          '/etc/init.d/tailscale']:
    print('%-46s %s' % (p, byp[p].size if p in byp else '不存在'))
```

判定：`wireguard.ko` 与 `tailscaled` 都在，且 `/etc/init.d/tailscale` 在（说明 procd 能托管开机自启）。

顺手查包数（比拆镜像快）：

```python
print(z.read('<设备名>.manifest').decode().count('\n'), '个包')
```

### 10.3 镜像尺寸

- 这个设备在编译期**没有**尺寸检查：`ipq807x.mk` 里 3 处 `IMAGE_SIZE` 都不属于 `redmi_ax6`，`image.mk` 只对 `KERNEL_SIZE` 做 `check-size`，而 `redmi_ax6-stock` 把 `KERNEL_SIZE` 清空了。
- 真正的上限写在 DTS：`ipq8071-ax6.dts` 把 rootfs 覆盖成 `reg = <0x2dc0000 0x5220000>`，即 **82.4 MB**。
- 所以尺寸超限不会在编译期报错，只会在刷机时出问题。加包后自己心里要有数。

### 10.4 设备侧（刷机后）

```sh
lsmod | grep wireguard        # 应看到 wireguard，且引用计数在
wg --version
tailscale version             # 没输出就是没进镜像
ls -l /etc/rc.d/S*tailscale   # 存在=开机自启；不想常开就 /etc/init.d/tailscale disable
```

---

## 11. 耗时与 ccache

- 冷缓存一轮：编译 83–89 分钟，整 job 95–98 分钟（#8 = 89.1 / 97.4，#9 = 82.8 / 95.5）。
- ccache 目录必须与源码树 `rules.mk` 第 355 行一致：`CONFIG_CCACHE_DIR` 为空时用 `$(TOPDIR)/.ccache`，也就是 `/mnt/ax6build/openwrt/.ccache`。
- 2026-11-24 之前缓存路径写错（缓存的是空目录 `/mnt/ax6build/.ccache`），实测证据：`ccache-45284063911`、`ccache-45031381400` 都是 0.00 GB；修正后 `ccache-45302764680` 为 0.26 GB。
- **首次真命中实测（2026-11-24 run #10 / `0dd84af`）**：#10 从 #9 存的 269.9 MB 归档恢复（步骤 7 耗时 0.02 → 0.15 分钟），编译 **62.7 分钟**、整 job **74.4 分钟**。对比 #9 的 82.8 / 95.5，**编译省 20.1 分钟（−24%）**，整 job 省 21.2 分钟。
- 归档体积会稳在 0.27 GB 量级：同一棵树第二轮只从 269.9 MB 涨到 272.1 MB（+2.2 MB），说明该树的编译单元基本都已在缓存里，重复跑不再显著增长。注意这是 zstd 压缩后的归档体积，不是 `.ccache` 目录的真实体积。
- 单轮耗时存在 runner 波动，但 20 分钟的量级远大于波动，可以认定是缓存带来的。
- 每次仍在重付的：`make download` 4.5–6.9 分钟、feeds 0.9–1.2 分钟，以及编译步骤内部的宿主工具 + 交叉工具链重建。

---

## 12. 权限与凭据

| 事项 | 方式 |
| --- | --- |
| 推代码 | SSH：`ssh://git@ssh.github.com:443/surfacexue/ax6-build.git`，钥匙由 Bitwarden SSH Agent 托管（`公司SSH`） |
| logs 分支推送 | 工作流内用 `${{ github.token }}`，靠 `permissions: contents: write` |
| 触发/重跑 | 推 main 即可；`Re-run` 按钮需网页登录或 PAT |
| 读 Actions 状态、产物元数据 | 匿名可读；**日志下载需要 token** |

---

## 13. 当前状态（2026-11-24 18:31）

| run | 提交 | 结果 | 编译耗时 | 整 job | 产物 |
| --- | --- | --- | --- | --- | --- |
| #8 | `dba6c59` | success | 89.1 分钟 | 97.4 分钟 | 98.9 MB |
| #9 | `3dec28f` | success | 82.8 分钟 | 95.5 分钟 | 98.9 MB |
| #10 | `0dd84af` | success | 62.7 分钟 | 74.4 分钟 | 98.9 MB |

- main 现为 `0dd84af`（把顶部注释补上 tailscale，`trigger-marker` 2→3）。
- run #9 与 #8 的产物内容等价：四路上游输入在两轮之间都没动（源码树 2025-06-11、luci 25.12 = 11-18、golang 27.x = 11-10、packages master = 11-23 21:20Z）。
- run #10 是第一次带真实缓存的编译，ccache 命中把编译从 82.8 分钟压到 62.7 分钟（省 20.1 分钟，−24%），产物仍是 98.9 MB。三个 `if: failure() || cancelled()` 的诊断步骤在这一轮按预期 skipped。
- 下一轮已做：把 `dl/` 纳入缓存（步骤 12，精确 key + 前缀回退），并在收集产物时打印 `.ccache` 与 `dl` 体积，见 §3.8。run #11（`3d4401a`）起生效。首次运行没有 dl 缓存可用，收益要到第二轮才显现。

---

## 14. 参考资料（权威源）

先说清一件事：**`build.yml` 是 GitHub 的东西，`.config` 不是。** 对 GitHub 而言 `ax6.config` 只是仓库里一个普通文本文件，GitHub 不解释它的内容；它由 OpenWrt 的 Kconfig 系统解释。

### 14.1 GitHub（workflow 语法）

| 文档 | 解决什么 |
| --- | --- |
| [Workflow syntax for GitHub Actions](https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions) | 唯一权威。`on` / `jobs` / `runs-on` / `steps` / `env` / `permissions` / `concurrency` / `timeout-minutes` 全部字段 |
| [Events that trigger workflows](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows) | `push` 的 `branches` / `paths` 写法，`workflow_dispatch` 的 `inputs` |
| [About GitHub-hosted runners](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners) | `runs-on` 的合法标签表（`ubuntu-22.04` / `24.04` / `latest` …）与机器规格 |
| [Contexts](https://docs.github.com/en/actions/learn-github-actions/contexts) | `${{ github.* }}` 能取哪些字段 |

### 14.2 OpenWrt（.config）

| 来源 | 解决什么 |
| --- | --- |
| [Build System Usage](https://openwrt.org/docs/guide-developer/toolchain/use-buildsystem) | menuconfig / defconfig / 编译流程 |
| [Build system essentials](https://openwrt.org/docs/guide-developer/toolchain/buildsystem_essentials) | 目录结构、配置文件在哪 |
| 源码树 `config/Config-*.in` | **Kconfig 字段定义本身**。本树共 7 项：`Config-build.in` / `Config-devel.in` / `Config-images.in` / `Config-ipq.in` / `Config-kernel.in` + 2 个检测脚本。`CONFIG_CCACHE_DIR` 就在 `Config-devel.in` 第 140–145 行 |
| 各包 `feeds/*/*/Makefile` 的 `define Package/...` | 某个包会产生哪些 `CONFIG_PACKAGE_*` 符号 |
| 运行时 `make menuconfig` / `make defconfig` | Kconfig 的最终真相；defconfig 生成 `tmp/.targetinfo`（设备清单） |

> openwrt.org 有反爬校验，`curl` 会被挡（返回 "Making sure you're not a bot!"）；用浏览器打开即可。
