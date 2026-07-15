# Semantouch

[English](README.md) | [简体中文](README.zh-CN.md)

面向 MCP 客户端的原生 macOS 计算机使用（computer use）能力。

Semantouch 是一个无外部依赖的 Swift 辅助程序，结合 ScreenCaptureKit 窗口捕获与
macOS Accessibility API。它通过 stdio
[Model Context Protocol](https://modelcontextprotocol.io/) 服务器暴露紧凑 UI 状态与原生操作，
并附带 [OMP](https://github.com/can1357/oh-my-pi) 插件。

[DeepWiki](https://deepwiki.com/watzon/semantouch) ·
[Star history](https://www.star-history.com/#watzon/semantouch&Date) ·
[Releases](https://github.com/watzon/semantouch/releases)

> [!IMPORTANT]
> Semantouch 可以观察并控制本机应用。请先阅读
> [安全模型](docs/SECURITY.md)，在合适时配置应用拒绝列表，并在执行有实质影响的操作前要求人工确认。

## 它提供什么

- 按窗口捕获，包括被其他窗口遮挡的窗口
- 带稳定元素 ID 的紧凑无障碍树
- 先完整快照、再增量树 diff
- 面向按钮、取值、选择与文本的语义无障碍操作
- 语义动作不可用时的受控键盘/指针回退
- 合成输入过程中的用户打断检测
- 不抢焦点、且从不参与正确性判定的虚拟光标叠加层
- 覆盖发现、启动、观察、全文读取、交互、等待与清理的 MCP 工具
- 独立 CLI，以及 OMP skills、诊断与 MCP 配置

Semantouch 只使用公开 Apple API，不依赖私有框架或专有 computer-use 二进制。

## 运行要求

- macOS 14.0 或更高版本
- Apple Silicon 或 Intel Mac（universal2 发布目标）
- 插件安装路径需要 [OMP](https://github.com/can1357/oh-my-pi)
- 下载已发布应用与检查 GitHub 更新时需要网络

仅在源码构建与开发时需要 Swift 工具链和 `just`。

> [!NOTE]
> **v0.2.1** 是最后一个旧版 arm64 helper release。自 **v0.3.2** 起，release
> 以 ZIP 和 DMG 发布已签名、已公证的 universal2 **`Semantouch.app`**；npm 与
> Homebrew 安装器使用同一个不可变 app ZIP。

## 使用 OMP 安装

直接安装带标签的 release：

```sh
omp plugin install github:watzon/semantouch#v0.3.2
```

或者把本仓库添加为 marketplace，再安装目录中的条目：

```sh
omp plugin marketplace add watzon/semantouch
omp plugin install semantouch@semantouch
```

重启 OMP。首次启动 MCP 时，插件启动器会优先使用本机已有的 `Semantouch.app`；
若不存在，则下载与插件版本匹配的已签名 app ZIP，校验 SHA-256，并安装到：

```text
~/Applications/Semantouch.app
```

若系统级与用户级安装同时存在，启动器优先使用：

```text
/Applications/Semantouch.app
```

MCP 客户端连接的是嵌套 relay：

```text
…/Semantouch.app/Contents/MacOS/semantouch
```

Accessibility 与 Screen Recording 权限归已签名的 app host
（`tech.watzon.semantouch` / `SemantouchHost`）所有，而不是嵌套 relay。

插件提供 `.mcp.json`、`semantouch` 与 `semantouch-setup` skills，以及
`/semantouch-doctor` 命令。验证集成：

```text
/mcp list
/mcp test semantouch
/semantouch-doctor
```

按 `doctor` 报告的精确身份授权：

- **Accessibility** — 系统设置 → 隐私与安全性 → 辅助功能
- **Screen Recording** — 系统设置 → 隐私与安全性 → 屏幕录制

> [!NOTE]
> macOS 隐私授权与代码签名、应用身份绑定。保留同一签名 `Semantouch.app` 身份的整包更新，
> 目标是延续既有授权。若换成新的裸 helper 路径或重新签名的身份，可能需要重新授权。
> 升级后务必重新运行 `doctor`。

权限排障、marketplace 升级、源码安装与手动 MCP 配置见
[Installation](docs/INSTALL.md)。

## 手动构建与运行

构建优化版可执行文件：

```sh
swift build -c release
SEMANTOUCH="$(swift build -c release --show-bin-path)/semantouch"
"$SEMANTOUCH" --version
"$SEMANTOUCH" doctor
```

生成指向该二进制的 MCP 配置：

```sh
"$SEMANTOUCH" config
```

或在 MCP 客户端配置中直接运行 stdio 服务器：

```json
{
  "mcpServers": {
    "semantouch": {
      "type": "stdio",
      "command": "/absolute/path/to/semantouch",
      "args": ["mcp"],
      "timeout": 30000
    }
  }
}
```

仓库内的 [`.mcp.json`](.mcp.json) 会解析插件启动器、开发安装路径或 `SEMANTOUCH_BIN`。
生成的打包示例使用 `/Applications/Semantouch.app/Contents/MacOS/semantouch`。

## MCP 工具

`tools/list` 当前按目录顺序暴露以下工具：

| 类别 | 工具 |
| --- | --- |
| 诊断与发现 | `doctor`、`list_apps`、`launch_app` |
| 状态与捕获 | `get_app_state`、`read_text`、`screenshot`、`end_app_session` |
| 语义交互 | `click`、`perform_action`、`set_value`、`select_text` |
| 输入与同步 | `scroll`、`press_key`、`type_text`、`drag`、`wait_for` |

在以元素为目标前先调用 `get_app_state`。元素 ID 绑定到单个 app session 与 revision；
过期 ID 会被拒绝，而不是错误地作用到其他控件。
仅需要像素时使用 `screenshot`——它不会推进无障碍树 revision。
当树字段被 256 字节上限截断、需要某个 revision 校验元素的完整值时，使用 `read_text`。
仅在显式、受策略门控的启动/恢复场景使用 `launch_app`——普通应用解析不会启动应用。

请求/响应示例、revision 语义与焦点行为见 [Usage](docs/USAGE.md)。
规范线协议见 [Protocol](docs/PROTOCOL.md)。

## 安全与过期 ID 行为

- 元素操作需要 `{ app, sessionId, revision, elementId }`。revision 不匹配返回
  `stale_revision`；未知 id 返回 `stale_element`。必须重新调用 `get_app_state` 并重新定位，
  不得复用或臆造 id。
- 回退输入默认 `background-only`：仅当目标已在前台时投递，否则返回 `focus_required` 且不投递任何输入。
- 合成输入期间若用户介入，会取消剩余输入并返回 `status: "interrupted"`。
- 观察到的 UI 文本与截图是不可信数据，绝不能当作授权。
- 使用 `SEMANTOUCH_DENIED_APPS` 配置操作员拒绝列表。拒绝列表不能替代操作时的人工确认。

细节见 [Security](docs/SECURITY.md)。

## 命令行接口

| 命令 | 用途 |
| --- | --- |
| `semantouch mcp` | 将 stdio MCP 中继到常驻 app host。标准输出仅保留 JSON-RPC。 |
| `semantouch call …` | 在同一 host session 上调用一个 MCP 工具或工具序列。 |
| `semantouch doctor [--json]` | 报告权限与 GitHub 更新可用性。 |
| `semantouch update [--json]` | 对最新整包 release 做发布者、校验和与版本校验后安装。 |
| `semantouch list-apps [--json]` | 列出应用及其窗口数量。 |
| `semantouch config [options]` | 生成 MCP 服务器配置或插件清单。 |
| `semantouch probe <kind> …` | 运行底层捕获与无障碍诊断。 |
| `semantouch --version` | 打印 helper、契约与 MCP 协议版本。 |

GitHub 不可用时 `doctor` 仍应成功，并将更新状态报告为 `unknown`。
Agent 工作流不得把“有可用更新”视为自动升级授权：必须先停下，请用户选择
**立即更新** 或 **暂不更新**。

`update` 将进度与失败写到标准错误；`--json` 把结果保留在标准输出供 agent 使用。
成功更新后，需重启 Semantouch 客户端才会生效。完整 `config` / `call` / `probe` 选项见
`semantouch --help`。

## 运行时配置

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `SEMANTOUCH_BIN` | 已发布或捆绑 helper | 在开发流程中用确切可执行路径覆盖 helper 发现。 |
| `SEMANTOUCH_DENIED_APPS` | 空 | 逗号分隔的精确应用标识、名称、路径或路径 basename，用于阻止。 |
| `SEMANTOUCH_CURSOR` | `on` | 将虚拟光标设为 `off`、`dim` 或 `on`。 |
| `SEMANTOUCH_WEB_AX` | 启用 | 设为 `off` 可关闭自动启用 Chromium/Electron 无障碍。 |
| `SEMANTOUCH_TRACE` | 关闭 | 设为 `1` 可在标准错误输出诊断跟踪。 |

应用拒绝列表不区分大小写，同时作用于读与写。默认空。示例：

```json
{
  "env": {
    "SEMANTOUCH_DENIED_APPS": "com.apple.Terminal,Terminal,com.apple.keychainaccess,Keychain Access"
  }
}
```

拒绝列表不能替代操作时确认。UI 文本与截图内容必须视为不可信数据，绝不能当作执行动作的授权。

## 架构

```text
MCP client
    │  stdio JSON-RPC
    ▼
semantouch (relay) ── private socket ── SemantouchHost
                                            ├── MCPServer / ComputerUseService
                                            ├── AccessibilityEngine
                                            ├── CaptureEngine
                                            ├── ActionEngine
                                            ├── CursorOverlay
                                            └── ComputerUseCore
```

协议进程保持标准输出仅承载 MCP 流量；诊断写入标准错误。
引擎模块在共享 DTO 与 session 策略之后隔离 Accessibility、ScreenCaptureKit、输入与叠加层。
嵌套 relay 不持有 TCC 授权。

模块边界与线程规则见 [Architecture](docs/ARCHITECTURE.md)。

## 开发

常用任务通过 `just`：

```sh
just build       # debug 构建
just test        # Swift 测试套件
just release     # 优化构建
just packaging   # 重新生成入库的 OMP 打包示例
```

`just packaging` 会有意生成指向
`/Applications/Semantouch.app/Contents/MacOS/semantouch` 的 release 布局示例。
不要手工编辑 [`packaging/`](packaging/) 中的生成 JSON。

贡献约定、权限/TCC 安全、协议兼容性与平台适配器对等要求见
[CONTRIBUTING.md](CONTRIBUTING.md)。

## 平台状态

| 表面 | 状态 |
| --- | --- |
| macOS 14.0+ Accessibility + ScreenCaptureKit | 支持目标 |
| universal2（`arm64` + `x86_64`）app 打包 | 仓库内发布契约 |
| Windows | 计划中；尚未发布 |
| Linux / Wayland | 计划中 / 受合成器能力门控；尚未发布 |
| npm / Homebrew 安装器 | 实验或进行中；此处不宣称 GA |

能力限制必须以类型化结果暴露，绝不能表现为静默空捕获或虚假成功。

## 文档

- [入门](docs/OVERVIEW.md)
- [安装与权限](docs/INSTALL.md)
- [工具用法](docs/USAGE.md)
- [线协议](docs/PROTOCOL.md)
- [安全模型](docs/SECURITY.md)
- [架构](docs/ARCHITECTURE.md)
- [测试夹具](docs/FIXTURE.md) 与 [验证矩阵](docs/TEST-MATRIX.md)
- [签名与发布流程](docs/RELEASE.md)
- [贡献指南](CONTRIBUTING.md)
- [行为准则](CODE_OF_CONDUCT.md)
- [English README](README.md)

## 许可证

[MIT](LICENSE)
