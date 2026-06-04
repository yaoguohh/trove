# ClipDeck

[English](README.md) · **中文**

[![Release](https://github.com/yaoguohh/clipdeck/actions/workflows/release.yml/badge.svg)](https://github.com/yaoguohh/clipdeck/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/yaoguohh/clipdeck)](https://github.com/yaoguohh/clipdeck/releases/latest)
[![License: MIT](https://img.shields.io/github/license/yaoguohh/clipdeck)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)

ClipDeck 是一个本地优先的 macOS 剪贴板管理器——键盘优先的悬浮面板,以可视卡片呈现剪贴历史,
用 Swift / AppKit + SwiftUI 原生构建。

## 功能

- 菜单栏应用,默认后台运行、不占 Dock 图标
- 横向时间线展示剪贴历史(文本、链接、图片、代码、邮箱、文件)
- **键盘优先**:搜索框**常驻聚焦**,打字即过滤;←/→ 切卡、回车粘贴——无需点击,首字母不丢
- 全局快捷键(默认 `⇧⌘V`),可在偏好设置中重新录制
- **空格**弹出快速预览气泡;右键「预览」打开可置顶的自适应大窗口
- **重命名**:在卡片头部行内改名(自定义名也可搜索)
- 收藏板:可改颜色 + 类似桌面图标的拖拽排序
- Dock 风格半透明玻璃面板;浅色/深色随偏好设置
- 链接标题 + favicon 预览,带本地元数据缓存
- 通过 [Sparkle](https://sparkle-project.org) 应用内自动更新
- 本地 JSON 存储于 `~/Library/Application Support/ClipDeck/`

## 键盘操作

`⇧⌘V` 唤出后,全程键盘:

| 按键 | 动作 |
|---|---|
| *打字* | 过滤历史(搜索框常驻聚焦) |
| `←` / `→` | 切换选中卡片 |
| `⌘←` / `⌘→` | 按屏翻页 |
| `回车` | 粘贴选中项 |
| `⌥回车` | 以纯文本粘贴 |
| `空格` | 快速预览选中卡片的气泡 |
| `⌦` / `⌘⌫` | 删除选中卡片 |
| `Esc` | 收起预览 → 清空搜索 → 关闭面板 |

鼠标:悬停卡片出现 **✎ 重命名**按钮;右键 **复制 / 预览 / 重命名 / 置顶 / 收藏到 / 删除**。把卡片拖出可将内容拖放进其它 App。

## 安装

从 [Releases](https://github.com/yaoguohh/clipdeck/releases) 页面下载最新的 `ClipDeck.dmg`,
打开后把 `ClipDeck.app` 拖进「应用程序」文件夹。

### 首次启动(重要)

ClipDeck 目前**未经 Apple 公证**(暂无付费开发者账号),所以首次启动会被 macOS Gatekeeper 拦截。
这是**一次性**的:

1. 双击 `ClipDeck.app`——macOS 提示「无法打开」。
2. 打开**系统设置 → 隐私与安全性**,滚到安全性区域,点 ClipDeck 旁边的**「仍要打开」**,
   输入密码确认。

(终端方式:`xattr -dr com.apple.quarantine /Applications/ClipDeck.app`)

放行这一次之后,**之后每次更新都会静默安装**——Sparkle 通过自己的连接下载更新、不带隔离属性,
Gatekeeper 不会再弹窗。

ClipDeck 还需要**辅助功能权限**(系统设置 → 隐私与安全性 → 辅助功能),以便用模拟的 `⌘V`
把内容粘贴到最前面的应用。

## 更新

ClipDeck 会在后台自动检查更新,也可通过**菜单栏 →「检查更新…」**手动检查,基于 Sparkle 的
EdDSA 签名 appcast(独立于 Apple 公证)。

## 从源码构建

```bash
swift build
swift test
```

## 打包签名 `.app`

```bash
bash scripts/package-app.sh        # → .build/ClipDeck.app
```

环境变量(本地开发均可省略):

| 变量 | 用途 |
|---|---|
| `CLIPDECK_SU_PUBLIC_KEY` | Sparkle EdDSA **公钥** → Info.plist 的 `SUPublicEDKey`(发布构建必需) |
| `CLIPDECK_SU_FEED_URL` | appcast 地址 → `SUFeedURL`(默认指向仓库的 `appcast.xml`) |
| `CLIPDECK_CODESIGN_IDENTITY` | 真实签名身份;默认 ad-hoc 签名 |

## 发布

完整的维护者操作手册见 [RELEASE.md](RELEASE.md)(一次性 Sparkle 密钥设置、每次发布的
构建 → appcast → GitHub Release 步骤,以及绝不能破坏的硬约束)。

## 许可证

[MIT](LICENSE) © 2026 yaoguohh
