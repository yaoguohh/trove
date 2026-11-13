# 开发说明

## 环境

- macOS 14 或更高。
- Xcode 的 Swift 6 工具链（CI 用 `latest-stable`）。项目开启 Swift 6 语言模式。

## 跑起来

两种方式，功能不同：

| 方式 | 命令 | 有什么 | 缺什么 |
|---|---|---|---|
| 直接运行 | `swift run` | 剪贴、面板、粘贴 | 没有本地化（界面固定英文）；没有 Sparkle 运行时，"检查更新"是灰的；辅助功能权限算在终端头上 |
| 打包安装 | `bash scripts/package-app.sh && bash scripts/install-local.sh` | 与发布版一致 | — |

`install-local.sh` 会退出正在运行的 Trove，用 `ditto` 替换 `/Applications/Trove.app` 并启动。打包默认用
ad-hoc 签名，designated requirement 固定为 bundle id，所以重复打包安装后辅助功能授权仍然有效。不要设置
`TROVE_CODESIGN_IDENTITY` 来打本地包——签名身份一变，授权就要重新给（见 [RELEASE.md](../RELEASE.md)
的硬约束）。

## 测试

```bash
swift test                                  # 全部
swift test --skip PanelControllerTests      # 跳过会在屏幕上弹出面板的那组
bash scripts/check-localization.sh          # 文案键检查（CI 也会跑）
```

- `PanelControllerTests` 会真实显示面板窗口，跑的时候屏幕上会闪一下。
- 存储相关测试用 `Tests/TroveTests/TestSupport.swift` 里的 `makeTempStore()`、`makeTempDirectory()`。
  每个 store 有自己的临时根目录，测试不会读写 `~/Library/Application Support/Trove/`。
- 有判断逻辑的地方先抽成纯函数再测（参考 `PanelKeyboard.intent`、`PasteboardIngest.decide`），
  不要在测试里驱动 `NSEvent` 或真实窗口。

## 约定

### 命名

- **Clipboard** 只指系统剪贴板；Trove 存的一条内容叫 **Clip**（`Clip`、`ClipKind`、`ClipStore`）。
- 面板相关一律以 **Panel** 开头。
- 两种预览只用两个词：空格弹出的气泡叫 **Peek**，独立窗口叫 **Inspector**。界面文案上统一显示为
  "预览"/"Preview"。
- 新类型放进职责对应的目录，守住 [ARCHITECTURE.md](ARCHITECTURE.md) 里的依赖方向；测试放在
  `Tests/TroveTests/` 的同名目录。

### 视觉

只从 `Theme` 取颜色、圆角、阴影、透明度和动效，规则与例外见 [DESIGN.md](DESIGN.md)。

### 文案

新增界面文案时，两个 `Localizable.strings` 都要加；不翻译的文字用 `Text(verbatim:)`。提交前跑
`scripts/check-localization.sh`。

### 并发

- 可变状态只在 `@MainActor` 上。
- 后台工作用 `Task.detached`，只把 `Sendable` 的结果带回来；不要把 `self` 送进后台任务。
- 阻塞调用（DNS 解析之类）放到 GCD 队列，不占用协作线程池。

### 数据格式

改 `history.json` 的结构时：

1. 提高 `StoreDocument.currentVersion`，在 `StoreDocument` 的注释里写明新版本改了什么。
2. 在 `Clip.init(from:)` 里迁移旧数据，加载后会自动写回一次。
3. 补一条从旧版本 JSON 读起的测试。

### 注释

注释解释机制和原因，不复述改动历史——"以前怎样"写在提交说明里。

### 待办

需要将来删掉的代码，在代码里标 `TODO(v<版本>)` 并写明条件。当前的待办：

- `TODO(v1.5)`：删除 `ClipStore.backfillThumbnails` 及其在 `AppDelegate` 里的调用（只服务从 v1.1.x 直接
  升级的用户）。

### 提交说明

一律用中文，格式为约定式提交：

```
type(scope): 一句话摘要

- 做了什么、为什么，一条一行
```

`type` 用 `feat`、`fix`、`perf`、`refactor`、`style`、`docs`、`test`、`build`、`chore`；`scope` 用目录名或
功能名（`store`、`panel`、`paste`、`links`、`scripts`……）。

## 发布

见 [RELEASE.md](../RELEASE.md)：正式发版只通过推送标签触发 CI。
