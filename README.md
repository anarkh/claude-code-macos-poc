# Claude 隔离工作台

面向 Apple Silicon Mac 的 SwiftUI / AppKit 实验应用，使用 Apple Virtualization.framework 在独立 Linux VM 中运行官方 Claude Code SDK/CLI 和 Firefox。当前源码版本为 **0.13.5 / build 27**。

会话支持 DeepSeek API 或 Claude 订阅、输入翻译、流式回复、本地会话和文本 Skills。未选择执行目录时保持纯文本聊天，无网卡、无宿主共享目录、无工具。选择项目目录后，每轮创建的 Linux VM 仅共享该目录，允许读取、搜索、编辑文件和运行项目命令。宿主 broker 负责模型请求与凭据，通过配置的 HTTP CONNECT 代理访问服务；MCP、agent/plugin 及项目设置中的自动 hooks 仍关闭。

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

**Claude 订阅账号与额度**

在「设置 → Claude Code → Claude 订阅」中添加账号名称和 Token，可分别重命名、更新授权、清除授权或删除账号。当前账号在会话标题旁显示，手动切换只影响下一次发送；请求、连接测试、停止清理和运行包维护期间不能切换。继续当前会话会把已有对话历史发送给新账号，也可选择切换并新建会话。切换账号不改变设备 ID、翻译配置、项目目录或浏览器资料。

账号页打开时查询额度，也可手动刷新，不进行后台定时查询。显示服务端返回的 5 小时、每周及可选模型窗口的已用比例、重置时间和最后更新时间；缺失值不填零，过期或查询失败的旧数据会明确标记。查询使用宿主的 HTTP CONNECT 代理，不启动 VM 或发送模型消息。`setup-token` 生成的长期 Token 仅支持模型请求，通常没有额度查询权限；此时显示不可用原因，保留正常聊天能力。本版本不增加官方登录或凭据续期流程。[官方 Token 说明](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token)

多账号使用 `Credentials/subscription-accounts.json`，目录权限 `0700`、文件权限 `0600`。首次启动把旧的 `subscription-token.json` 导入为默认账号，并回读验证；以后只使用新账号文件，文件损坏时不会静默退回旧 Token。旧文件保留用于回退，因此清除当前账号授权不会删除历史迁移备份。旧 App 不认识多账号；回退前保留新账号文件，并注意旧版仍读取迁移时的单个 Token。账号列表的变化不改变会话文件格式。

**会话执行目录**

在会话标题旁选择「执行目录」。每个会话独立保存目录，重启后恢复；执行期间该会话不能更换目录，其他会话可以选择不同项目。「取消目录关联」恢复纯文本模式，不删除项目或对话记录。目录不存在、权限不足或启动期间发生变化时会明确报错，不退回其他目录执行。

所选目录及其内容以读写方式挂载到 VM 的 `/home/claude/project`，文件修改直接反映到本机，停止请求不会回滚已经写入的文件。不允许选择整个主目录或包含 App 私有数据的目录，App 保存的模型凭据留在宿主；文件工具限制在所选目录内，命令在 Linux VM 中执行，不能调用宿主 macOS 程序。VM 无网卡，项目命令的外部依赖下载不在当前能力范围内；需要 Linux 可用的依赖和工具。文本 Skills 只添加提示文本，不额外授予工具、MCP 或网络权限。

项目执行需要支持 `selected-directory-rw/v1` 的运行包。旧包仍可用于纯文本会话，项目请求会在启动前明确拒绝；更新检查对声明项目能力的运行包额外执行读文件、写文件和命令运行的 VM 合成检查。

**身份与请求诊断**

Claude 订阅模式使用安装级随机 `device_id`，保存在用户 Application Support 下的 `ClaudeIsolationPoC/Identity/installation.json`，不会随每次请求轮换。`session_id` 使用 App 的会话 UUID，同一会话跨轮保持不变，新建会话生成新 ID；DeepSeek API 模式不使用这组身份字段。在「设置 → Claude Code → Claude 订阅」中可手动「更换设备 ID」，确认后供后续请求使用；执行请求、连接测试或维护任务期间不可更换。更换会保留登录凭据、历史记录及已有对话的会话 ID。

请求诊断默认只保存摘要。在设置的「请求诊断」中显式开启完整正文采集后，从下一次发送起保存诊断正文，保留 24 小时；到期后不可查看或导出，App 运行时清理过期副本，退出期间到期的副本在下次启动时清理。历史 v1 诊断正文不会自动删除，可手动清理；清理保留对话消息和请求摘要，关闭采集不会立即删除已有正文。

诊断导出默认仅包含摘要，先预览再复制或保存。需要正文时须单独勾选「包含已脱敏正文」；导出会处理身份字段、metadata 和可识别凭据，但正文仍可能包含对话、代码及其他敏感信息，分享前应检查预览。已导出的文件和剪贴板内容不受 App 的 24 小时清理规则管理。

当前 App 可读取 v1/v2 会话文件，保存时使用包含可选执行目录的 v3 格式；旧 App 无法读取 v3。回退 App 前应备份并保留现有数据，如需旧版使用，应恢复升级前的兼容备份，不要通过清空数据绕过版本错误。

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
