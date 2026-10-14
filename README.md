# Claude 隔离工作台

面向 Apple Silicon Mac 的 SwiftUI / AppKit 实验应用，使用 Apple Virtualization.framework 在独立 Linux VM 中运行官方 Claude Code SDK/CLI 和 Firefox。当前源码版本为 **0.13.2 / build 24**。

文本会话支持 DeepSeek API 或 Claude 订阅、输入翻译、流式回复、本地会话和文本 Skills。文本 VM 每轮创建，无网卡和宿主共享目录；宿主 broker 负责模型请求与凭据，通过配置的 HTTP CONNECT 代理访问服务。项目文件、Shell 和 MCP 工具执行仍关闭。

浏览器使用单独的 Firefox VM 和持久资料盘，支持窗口尺寸调整、正常停止/重启，以及显式触发的一次纯文本粘贴。生产浏览器 VM 无网卡和宿主共享目录，通过 vsock 接入宿主代理。浏览器镜像准备阶段会使用 NAT 下载公共系统依赖。

**构建要求**

- Apple Silicon、macOS 14+、Swift 6 工具链（Command Line Tools 或 Xcode）、Python 3；脚本也会调用系统 `/usr/bin/python3`。
- Node.js 与 npm；浏览器内核解压需要 `node:zlib.zstdDecompressSync`，建议 Node 24+。下方命令使用当前 Node 的绝对路径，也可用 `BROWSER_KERNEL_NODE` 指定具备该能力的 Node。
- APFS 工作目录，用于 `cp -c` 创建 VM 磁盘克隆；预留公共下载、两类 8 GiB 逻辑根盘及构建副本所需空间。
- 可访问官方 npm registry、Ubuntu cloud image/apt 仓库和 Mozilla 下载站。依赖版本与摘要固定，上游制品不可用或摘要不匹配时准备会失败。

基线固定为 Agent SDK **0.3.295**、Claude CLI **2.1.295**、Linux Node **26.7.0**、Ubuntu noble **release-20260926**；浏览器为 Firefox **157.0.1** ARM64 日语版、Ubuntu 内核 ABI **7.0.0-38-generic**。App 内运行包更新与源码基线版本独立。

**首次准备与构建**

在仓库根目录执行。以下步骤会下载公共依赖并启动准备 VM；命令已按源码核对，本次源码发布没有验证全新机器的完整构建。

```bash
poc_node="$(node -p 'process.execPath')"
"$poc_node" -e 'if (typeof require("node:zlib").zstdDecompressSync !== "function") process.exit(1)'
mkdir -p sdk/.install-home sdk/.install-tmp sdk/.npm-cache
(
  cd sdk
  env -i PATH="$(dirname "$poc_node"):/usr/bin:/bin" \
    HOME="$PWD/.install-home" TMPDIR="$PWD/.install-tmp" \
    npm_config_cache="$PWD/.npm-cache" \
    npm ci --ignore-scripts --no-audit --no-fund \
      --registry=https://registry.npmjs.org
)
POC_NODE_BIN="$poc_node" sh sdk/prepare-linux-native.sh

python3 host/prepare_image.py
python3 host/prepare_node.py
python3 host/prepare_atomic.py
bash host/text-runtime/build.sh
python3 host/text-runtime/prepare.py
bash host/browser-runtime/build.sh
BROWSER_KERNEL_NODE="$poc_node" python3 host/browser-runtime/prepare.py

mkdir -p app/dist
bash app/build_app.sh "$poc_node"
open app/dist/ClaudeIsolationPoC.app
```

成功时生成 `app/dist/ClaudeIsolationPoC.app`。构建会运行文本桥、更新模块及 Swift 自检，并对 App/helper 进行本地 ad-hoc 签名与严格签名核验。App 使用外部 Node 的绝对路径，Node 不随包分发；尚未完成 Developer ID 签名、公证或跨机器分发验证。

准备脚本拒绝覆盖已有镜像，App 构建拒绝覆盖已有输出包。重新构建前先保留需要的旧产物；不要对使用中的 VM 磁盘执行重置。`host/prepare_image.py --reset-test-disk` 会丢弃该目录的测试盘，不属于常规增量构建步骤。

首次使用在设置中配置自己的模型凭据和 HTTP CONNECT 代理。凭据以本机专用文件保存，不使用 Keychain；文件权限限制访问但内容未加密。实际模型请求需要有效账号/Key，可能产生提供商费用。

**源码入口**

| 路径 | 内容 |
| --- | --- |
| `app/Sources/ClaudeIsolationPoC/` | UI、会话、凭据、VM 生命周期、代理和运行包更新 |
| `app/tools/`、`app/tests/` | 图标/运行包打包工具与集成检查 |
| `host/Sources/`、`host/text-runtime/` | Swift VM helper、文本镜像准备和启动器 |
| `host/browser-runtime/` | 浏览器镜像准备、内核解压和验证工具 |
| `guest/text-runtime/`、`guest/browser-runtime/` | guest 运行协议、Firefox 策略、显示/粘贴/停止服务 |
| `guest/native/`、`guest/relay/`、`sdk/` | SDK 桥与早期原生隔离、来源和 relay 实验 |
| `translation/`、`network/`、`runtime/`、`updates/` | 翻译、CONNECT transport、时区/语言配置、更新协议 |

可单独运行不启动 VM 的浏览器 guest 逻辑检查：

```bash
python3 -m unittest discover -s host/browser-runtime -p 'test_*.py'
node --test network/test-proxy-transport.mjs runtime/test-profile.mjs
```

`host/browser-runtime/verify.py` 会启动真实图形 VM。`finalize_candidate.py` 是历史候选发布辅助脚本，依赖既有验证输出和特定历史日志，不属于首次构建流程。

**仓库中的测试资料与本机数据**

`host/evidence/native-23.json` 是保留的本地假服务测试样本（`fake_only`），Swift replay 自检必须读取它，覆盖六次工具调用及完成/失败状态。它不代表真实模型、账号鉴权或生产隔离验收。其余历史验收日志和本机使用记录不随源码发布。

`network/fixtures/` 的证书/私钥以及更新测试中的 TLS 材料仅供本地测试，不能作为生产凭据或信任根；它们不会打包进 App。运行包构建在本机专用目录生成签名私钥，不应提交到仓库。

下载缓存、第三方运行时、VM 镜像、App 构建产物、浏览器资料、会话与真实凭据均应留在本机。第三方公共制品通过准备脚本获取，其许可证和声明随制品保留；本仓库不提供这些二进制制品的再发行授权。
