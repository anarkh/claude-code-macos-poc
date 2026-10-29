# 项目协作约定

本文件适用于整个仓库，记录 Claude 隔离工作台特有的开发和验收约束。首次构建与依赖准备见 [README.md](README.md)；不要把临时任务进度、机器路径、账号信息或历史验收结果写进本文件。

## 定位改动范围

- 本仓库包含 macOS App、宿主 broker/VM helper、Linux guest 运行时和镜像准备工具。以 `git rev-parse --show-toplevel` 确认仓库根目录，只提交本项目的改动。
- UI、会话和生命周期从 `app/Sources/ClaudeIsolationPoC/` 入手；文本请求跨越 `sdk/vm-text-chat.mjs`、`host/text-runtime/` 和 `guest/text-runtime/`。浏览器逻辑跨越 App 的 `Browser*` 文件、`host/browser-runtime/` 和 `guest/browser-runtime/`。
- `guest/native/`、`guest/relay/` 和部分 `sdk/run-*.mjs` 属于早期实验；修改前确认它们是否进入当前 App 的打包和调用链。发布包的实际文件清单以 `app/build_app.sh` 为准。
- 修改 guest 代码不会自动改变已有磁盘或已安装 App。涉及 guest 行为时，必须把对应镜像重建、打包和运行验证纳入交付。

## 保持现有隔离契约

- 正常运行的 VM 均无网卡。纯文本会话和浏览器 VM 无宿主目录共享；用户在会话中显式选择项目目录时，项目 VM 仅以读写方式共享该目录到固定 guest 路径，不共享整个主目录或 App 私有数据。浏览器镜像准备阶段的 NAT 仅用于下载公共依赖，不能带入正式运行配置。
- 模型和浏览器流量通过宿主 broker/代理及 vsock 传输。保留显式 HTTP CONNECT 代理、目标证书校验和错误路径；代理失败时不得静默直连，也不能关闭 TLS 校验来让测试通过。
- 未选择项目目录的文本运行时使用空工具集；项目模式仅启用 Read、Write、Edit、Bash、Glob、Grep，命令在 Linux VM 内执行。MCP、agent/plugin 和项目设置中的自动 hooks 仍关闭。文本 Skills 不代表工具授权；增加其他共享目录、工具或网络能力属于功能与权限范围变化，须有用户明确授权。
- 模型真实凭据留在宿主，guest 只使用受控的占位凭据。不得把真实 Key/Token 放进 VM seed、镜像、协议转储或日志。
- 浏览器粘贴由用户显式触发，每次只传纯文本；不得改成后台读取剪贴板、持续同步或隐式文件共享。
- 浏览器资料盘是持久用户数据，根盘克隆是可清理的临时产物。资料盘租约必须保持到 VM 完全停止；停止、重启、退出及失败清理不能提前释放锁或删除仍在使用的磁盘。

## 保护本机状态

- 凭据、会话、浏览器资料和已导入运行包位于用户 Application Support 下；配置还包含 UserDefaults。定位路径应读相应 Store/Configuration 实现，不硬编码开发者主目录。
- 安装替换、真实账号测试或可能改变持久数据的操作前，记录相关文件的摘要、大小、权限及配置值；操作后回读核对。快照留在权限受限的本机位置，日志和提交中不得出现凭据内容。
- 测试优先使用临时目录、独立 UserDefaults suite 和合成凭据。不得为了通过测试清空用户会话、重置登录、删除浏览器资料、修改代理配置或切换真实模型配置。
- 持久化 schema、运行包 manifest 或协议变更需同步处理读写端、兼容检查和相应测试。遇到不兼容数据要保留原数据并明确报错，不静默重建覆盖。
- 构建失败不代表用户数据损坏。镜像重置、凭据重建、信任根更换等操作不能作为通用修复步骤；只有任务已明确授权相关影响时才执行。

## 按改动选择验证

以下命令均在仓库根目录执行。只运行与本次改动相关的检查；纯文档改动核对路径、命令和 diff 即可。

| 改动 | 最小验证入口 |
| --- | --- |
| 浏览器 guest 的尺寸、粘贴、窗口配置、停止逻辑 | `python3 -m unittest discover -s host/browser-runtime -p 'test_*.py'` |
| 网络策略、时区和语言 | `node --test network/test-proxy-transport.mjs runtime/test-profile.mjs` |
| 翻译协议和内容保护 | `node --test translation/test-*.mjs` |
| 运行包下载、校验和更新 | `node --test updates/test-*.mjs`，需要系统 Python；使用本地假服务/helper |
| 文本桥、请求追踪与 guest 文本契约 | 下方明确列出的 Node 测试 |
| 项目目录挂载、工具执行与多轮消息 | 文本路径检查，加 `node --test sdk/test-project-provider-protocol.mjs sdk/test-project-relay.mjs`、`python3 -m unittest discover -s host/text-runtime -p 'test_project_launch.py'`；真实 VM 使用合成临时项目验证读写、命令、取消与目录边界 |
| Swift UI、配置、存储、生命周期 | Swift 编译与 App 内置 `--self-test`；本项目不以 `swift test` 作为 App 自检入口 |

文本路径的离线检查使用显式文件名：

```bash
node --test sdk/test-vm-text-chat.mjs sdk/test-request-trace.mjs \
  sdk/test-owned-run-directory.mjs sdk/test-origin-contract.mjs \
  guest/text-runtime/test-runtime.mjs
```

这些离线检查可启动临时进程或 loopback 假服务，不需要真实模型凭据。不要笼统运行 `node --test sdk/test-*.mjs`：其中包含依赖官方 CLI、Seatbelt 或真实 VM 的集成测试，须先查看目标测试的运行条件。

Swift 自检需要 macOS、Swift 6、Node 和系统 `sandbox-exec`，无需 VM 镜像、SDK 安装或真实 Key。保留 `host/evidence/native-23.json`；它是 replay 自检必需的 `fake_only` 合成样本。使用明确的 fixture 参数，避免把检查结果误认为完整自检：

```bash
poc_node="$(node -p 'process.execPath')"
swift build --package-path app -c debug --arch arm64
poc_bin_dir="$(swift build --package-path app -c debug --arch arm64 --show-bin-path)"
"$poc_bin_dir/ClaudeIsolationPoC" --self-test \
  --fixture-project-root "$PWD" --fixture-node "$poc_node"
```

修改 UI 或 VM 交互后，应在实际 App/VM 中验证本次行为。例如尺寸变化需检查画面与鼠标坐标一致，粘贴需检查目标输入框及正常键盘输入，生命周期需检查停止、重启、退出和资料保留。静态检查、单测和编译通过不能代替这类验收；屏幕锁定或环境缺失时明确记录未验证项。

## 构建与安装

- 使用 Apple Silicon、macOS 14+、Swift 6 和 APFS；Node 必须是可执行的绝对路径。首次镜像准备、隔离 npm 安装及 Node 解压能力要求按 README 执行，不读取个人 npm/Claude 配置来补齐构建环境。
- 已准备好文本与浏览器镜像后，先创建 `app/dist`，再运行 `bash app/build_app.sh "$poc_node"`。该脚本会执行指定测试、自检、镜像校验和 ad-hoc 签名，拒绝覆盖既有输出包。
- 增量打包可使用第二个参数指定新的输出路径，例如 `bash app/build_app.sh "$poc_node" "$PWD/app/dist/ClaudeIsolationPoC-candidate.app"`。第三个参数可选择浏览器镜像目录；不要为绕过校验改写 manifest 或删除完整性检查。
- 依赖版本与摘要以准备脚本、`sdk/package-lock.json`、guest 常量和镜像 manifest 为准。SDK 与 CLI 的版本号独立；升级需同步相关固定值与校验，不从 SDK 版本推算 CLI 版本。
- `host/prepare_image.py --reset-test-disk` 会重置测试盘；`patch_candidate.py`、`recover_hwe.py`、`finalize_candidate.py` 是专用维护入口，部分依赖历史产物，不能作为默认构建或修复流程。
- `host/run_relay_fixture.py` 内部会调用测试盘重置。运行集成脚本前检查其下载、磁盘写入和子进程行为，不能仅凭名称含有 `test` 或 `fixture` 判断它没有副作用。
- 只有任务包含安装或运行验证时才操作已安装 App。替换前正常停止 VM 并退出 App，保留可回退产物；替换后核对运行中的版本、真实行为及用户状态。候选包构建成功、已安装、已验收是不同状态。

## 提交与公开仓库

- 提交前检查 `git status`、实际 diff 和暂存文件清单。只包含本次源码、测试或文档变更；不要强制加入被忽略的本机产物。
- 不提交真实凭据、用户配置、会话、浏览器资料、原始请求记录、VM 镜像、下载缓存、构建包和运行包签名私钥。新增生成目录时同步检查 `.gitignore`。
- `host/evidence/native-23.json` 和 `network/fixtures/`、更新测试中的 TLS 材料是有意保留的合成测试资料。不要因泛化清理删除它们，也不能把这些测试证书用作生产信任根。
- 运行包构建会生成本机签名私钥；不得发布或用测试密钥替换。更新信任机制需要明确的兼容与迁移安排。
- 交付说明列明实际通过的检查、未验证项和环境阻塞。涉及 GitHub 推送、安装或更新时回读目标状态，不把命令接受、构建成功或进程启动当作最终结果。
