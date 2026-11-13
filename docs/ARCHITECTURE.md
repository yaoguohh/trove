# 架构说明

Trove 是一个 macOS 菜单栏应用：后台轮询系统剪贴板，把每次复制存成一条 **Clip**；用户按快捷键唤出
**面板**，选中一张卡片后把它粘贴回原来所在的应用。整个应用是一个 SwiftPM 可执行目标，唯一的外部依赖
是 Sparkle（自动更新）。

本文讲模块怎样划分、状态归谁、两条主流程怎样走、数据怎样落盘。做过的取舍及其理由见 [ADR](adr/README.md)，
视觉规范见 [DESIGN.md](DESIGN.md)，开发与提交约定见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 术语

| 词 | 含义 |
|---|---|
| Clipboard | 只指 macOS 的系统剪贴板（`NSPasteboard`）。 |
| Clip | Trove 存下的一条内容（文本或图片），类型 `Clip`。 |
| 卡片（Card） | Clip 在面板上的样子，类型 `ClipCard`。 |
| 面板（Panel） | 快捷键唤出的悬浮窗，类型 `PanelController`、`PanelView`、`PanelWindow`。 |
| Peek | 在面板里按空格弹出的气泡，只看一眼，选中一变就关。 |
| Inspector | 点击 Peek 或右键「预览」打开的独立窗口，可以选中文字、并排比较。 |
| 置顶（Pin）、收藏板（Pinboard） | 置顶的 Clip 不会被淘汰；收藏板是置顶 Clip 的分组。 |
| Sidecar | 存在 `history.json` 之外的文件：图片、缩略图、超长文本。 |
| 内容身份（content hash） | 判定"两条是不是同一内容"的唯一依据，见下文"不变量"。 |
| 粘贴目标 | 唤出面板时位于最前面的应用及其焦点元素，粘贴要送回这里。 |

## 模块

源码在 `Sources/Trove/` 下按职责分为 14 个目录，测试在 `Tests/TroveTests/` 下用同样的目录。

| 目录 | 职责 | 主要类型 |
|---|---|---|
| `Support/` | 被各处引用的基础设施：设置、日志、版本信息、权限、路径、键码 | `AppSettings`、`Log`、`AppInfo`、`AccessibilityPermission`、`ClipboardAccessPermission`、`AppPaths`、`KeyCode`、`HotKeyShortcut` |
| `Model/` | 数据模型与纯规则 | `Clip`、`ClipKind`、`Pinboard` |
| `Storage/` | 历史的唯一来源与落盘 | `ClipStore`、`ClipFiles`、`HistoryPersistence`、`HistoryWriter`、`ImageFiles`、`ImageCache`、`ClipSearch` |
| `Capture/` | 监听系统剪贴板，决定收不收、收成什么 | `ClipboardMonitor`、`PasteboardIngest`、`ImageIngest` |
| `Paste/` | 把 Clip 写回剪贴板并送进粘贴目标 | `ClipPasteboard`、`PasteExecutor`、`PasteTargetSnapshot` |
| `Hotkey/` | 全局快捷键的注册与录制 | `HotKeyManager`、`ShortcutRecorder` |
| `Panel/` | 面板窗口、键盘路由、搜索与筛选、收藏板条 | `PanelController`、`PanelView`、`PanelViewModel`、`PanelKeyboard`、`PanelKeyEvent`、`PinboardStrip` |
| `Card/` | 卡片及其内容、拖拽 | `ClipCard`、`CardMetrics`、`CardDragSurface` |
| `Peek/` | 空格弹出的气泡 | `PeekController`、`PeekView` |
| `Inspector/` | 独立的检查窗口及其内容判定 | `InspectorController`、`InspectorRenderer`、`InspectorViews`、`EditingShortcuts` |
| `Links/` | 链接卡片的标题与图标 | `LinkMetadataProvider`、`LinkAddressGuard`、`HTMLHead`、`LinkCardText` |
| `SourceApp/` | 来源应用的图标与配色 | `SourceAppIconProvider`、`SourceAppStyle` |
| `Design/` | 视觉令牌与共用的视觉组件 | `Theme`、`ThemeModifiers`、`PinboardColor`、`ImageUnavailableView` |
| `App/` | 组合根、状态菜单、自动更新 | `AppDelegate`、`StatusMenuController`、`StatusMenuView`、`UpdaterController` |

### 依赖方向

```
App ──────────────▶ 其余所有目录（组合根，没有目录引用它）
Panel ────────────▶ Card、Peek、Inspector、Paste、Storage、Model、Design
Card ─────────────▶ Storage、Model、Design、Links、SourceApp（面板的组成部分，可引用 PanelFocus）
Peek ─────────────▶ Inspector、Storage、Model、Design（面板的组成部分，可引用 PanelViewModel）
Inspector ────────▶ Storage、Model、Design
Paste ────────────▶ Capture（告知自己写回）、Storage、Model
Capture ──────────▶ Storage、Model
Storage ──────────▶ Model
Links、SourceApp、Hotkey ─▶ Support、Design、Model
所有目录 ─────────▶ Support
```

新增代码时守住两条：Storage 和 Model 不引用任何界面目录；只有 App 可以把模块装配在一起。

## 状态归属

所有可变状态都在 `@MainActor` 上，每份状态只有一个所有者。

| 状态 | 所有者 | 说明 |
|---|---|---|
| 历史（全部 Clip 与收藏板） | `ClipStore` | 唯一来源；维护显示顺序；所有增删改都经过它 |
| 删除撤销栈 | `ClipStore` | 仅在内存，最多 25 条，不落盘 |
| 文件位置、全文读取 | `ClipFiles`（由 `ClipStore` 持有并注入） | 视图经 `@Environment(\.clipFiles)` 拿到，AppKit 控制器经构造参数拿到 |
| 搜索词、筛选、选中、重命名中的卡片 | `PanelViewModel` | 筛选结果每次变化只算一次并缓存 |
| 面板是否显示、Peek、Inspector 窗口 | `PanelController` | 面板上的窗口级动作（粘贴、复制、预览）也由它执行 |
| 粘贴目标 | `ClipPasteboard` | 唤出面板前记下，用一次即清 |
| 用户设置 | `AppSettings.shared` | 视图直接绑定；`AppDelegate` 订阅快捷键与后台运行的变化 |
| 快捷键是否注册成功 | `HotKeyManager` | 状态菜单打开时读取 |

## 主流程

### 复制 → 入库

1. `ClipboardMonitor` 每 0.5 秒比较一次 `changeCount`，没变就什么都不做。
2. 变了就读类型列表，交给纯函数 `PasteboardIngest.decide`：先按类型跳过密码管理器（concealed）和
   文本扩展工具（transient）写的内容——这时还没读过内容；再决定收文本还是收图片（文本优先，文本只是
   图片地址时才收图片）。
3. 文本：`ClipStore.add(text:)` 计算内容身份；已有同样内容就把那张卡移到最前，否则新建。超过 2 万
   字符的文本把全文写进 `texts/` 下的 sidecar，`history.json` 只留前缀。
4. 图片：在后台任务里转成 PNG（`ImageIngest`）、写文件并生成缩略图（`ImageFiles`），算出 PNG 字节的
   哈希，再回到主线程交给 `ClipStore.addPreparedImage`。
5. `ClipStore` 每次变更只发布一次 `items`，去抖 0.3 秒后由 `HistoryWriter` 在串行队列里写盘。

### 唤出 → 粘贴

1. 快捷键（Carbon `RegisterEventHotKey`）或左键点菜单栏图标触发 `AppDelegate.togglePanel`。
2. `ClipPasteboard.rememberTarget()` 记下当前最前面的应用和它的焦点元素（粘贴目标）。
3. `PanelController.show()` 以不抢激活的方式显示面板（`.nonactivatingPanel`），粘贴目标仍是活动应用。
4. 键盘事件由面板窗口级的本地监听统一接收，经纯函数 `PanelKeyEvent.decode` 与
   `PanelKeyboard.intent` 决定意图；可打印字符交给搜索框。
5. 回车或点击卡片：面板立即隐藏，`ClipPasteboard.paste` 把内容写回剪贴板（并告知 `ClipboardMonitor`
   这是自己写的），再由 `PasteExecutor` 送进粘贴目标：先用辅助功能接口直接插入；不行就只抬起目标的
   前窗再试一次；最后合成 ⌘V。

## 并发

- 状态只在主线程（`@MainActor`）上改。项目开启 Swift 6 语言模式。
- 耗时工作放到 `Task.detached`，只把 `Sendable` 的结果带回主线程：图片编码、缩略图回填、链接抓取、
  链接缓存清理。
- 阻塞调用不占用协作线程池：DNS 解析（`getaddrinfo`）放到 GCD 队列。
- 写盘由 `HistoryWriter` 串行化：去抖写入只有在其后没有新的写入请求时才落盘，退出时的 `flush`
  同步写入并让所有未完成的写入作废。

## 数据与文件

| 位置 | 内容 |
|---|---|
| `~/Library/Application Support/Trove/history.json` | 全部 Clip 与收藏板，带 `version` 字段 |
| `…/Trove/images/` | 图片原样的 PNG（`<id>.png`）与缩略图（`<id>.thumb.png`，原图够小时就是原图本身） |
| `…/Trove/texts/` | 超过 2 万字符的全文（`<id>.txt`） |
| `~/Library/Caches/Trove/link-metadata/` | 链接标题与图标的缓存，可随时删除 |
| `UserDefaults`（`io.github.yaoguohh.trove`） | 设置，键名集中在 `AppSettings.Key` |

`history.json` 的格式版本记录在 `StoreDocument.currentVersion`，旧版本在解码时迁移（见
`Clip.init(from:)`），加载后写回一次。读不出（权限、I/O 错误）时本次运行不写盘，解不开时先备份成
`history.corrupt-*.json` 再从空历史开始。启动时清掉 `images/`、`texts/` 里没有任何 Clip 引用的文件。

## 不变量

- **一份内容一张卡**：`contentHash` 是唯一的去重依据——文本取去掉首尾空白后的 SHA-256，图片取 PNG
  字节的 SHA-256。新增、撤销删除都按它去重；没有身份的旧图片不参与去重。
- **显示顺序**：置顶的在前，其余按复制时间从新到旧；每次变更后由 `ClipStore` 重新确立，读者不排序。
- **先落盘再引用**：sidecar 写成功之后，Clip 才进入历史；崩溃最多留下孤儿文件，不会留下指向不存在
  文件的引用。
- **删除可撤销**：删除时不删文件，直到它被挤出撤销栈；清空历史和淘汰超出上限的 Clip 时才真正删文件。
- **自己写回的不再入库**：`ClipPasteboard` 每次写剪贴板后都调用 `ClipboardMonitor.acknowledgeOwnWrite()`。
- **大内容不拖慢界面**：展示和搜索只处理有上限的前缀（`Clip.excerptCap`、`ClipSearch.scanCap`），
  检查窗口最多排版 256 KB（`InspectorController.textBudget`）。

## 测试

纯判断都抽成了纯函数并有单元测试：`PanelKeyboard.intent`、`PanelKeyEvent.decode`、
`PasteboardIngest.decide`、`ClipSearch.filter`、`LinkCardText.make`、`InspectorRenderer`、
`EditingShortcuts`、`ImageFit`、`LinkAddressGuard`、`HTMLHead`。存储相关测试用 `TestSupport` 里的
`makeTempStore()`，每个 store 有自己的临时根目录，sidecar、启动清理、缩略图回填、淘汰删文件都真实
运行，不会碰到用户数据。
