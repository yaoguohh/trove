# Trove

[English](README.md) · **中文**

[![Release](https://github.com/yaoguohh/trove/actions/workflows/release.yml/badge.svg)](https://github.com/yaoguohh/trove/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/yaoguohh/trove)](https://github.com/yaoguohh/trove/releases/latest)
[![License: MIT](https://img.shields.io/github/license/yaoguohh/trove)](LICENSE)
![Platform: macOS 14+, Apple Silicon and Intel](https://img.shields.io/badge/platform-macOS%2014%2B%20%C2%B7%20Apple%20Silicon%20%2B%20Intel-blue)

Trove 是一个本地优先的 macOS 剪贴板管理器——键盘优先的悬浮面板,以可视卡片呈现剪贴历史,
用 Swift / AppKit + SwiftUI 原生构建。

## 功能

- 菜单栏应用,默认后台运行、不占 Dock 图标
- 横向时间线展示剪贴历史(文本、链接、图片、代码、邮箱)
- **键盘优先**:搜索框**常驻聚焦**,打字即过滤;←/→ 切卡、回车粘贴——无需点击,首字母不丢
- 全局快捷键(默认 `⇧⌘V`),可直接在菜单栏菜单里重新录制
- **空格**弹出快速预览气泡;右键「预览」打开可置顶的自适应大窗口
- **富检查窗口**:文本可原生选中(⌘C / 右键复制)、JSON 美化展示;单个 URL 直接用默认浏览器打开
- **⌘Z 恢复刚删除的剪贴**——多级撤销
- 大剪贴优雅处理——展示与搜索始终流畅,超大内容溢出到 sidecar 文件
- **重命名**:在卡片头部行内改名(自定义名也可搜索)
- 收藏板:各有自己的颜色,类似桌面图标的拖拽排序
- Dock 风格半透明玻璃面板,单一深色 anthracite 配色:一个强调色、三级表面、发丝线描边
- 右键菜单栏图标弹出紧凑菜单——快捷键、链接预览、后台运行全部内联(不再有独立偏好窗口)
- 链接标题 + favicon 预览,带本地元数据缓存(默认关闭,在菜单栏菜单里打开「链接预览」;抓取会让链接所在网站知道你复制了它)
- 通过 [Sparkle](https://sparkle-project.org) 应用内自动更新
- 历史默认保留 500 条未置顶的内容(`defaults write io.github.yaoguohh.trove Trove.maxItems 1000` 可改,范围 50 到 5000);置顶的内容不会被淘汰

## 键盘操作

`⇧⌘V` 唤出后,全程键盘:

| 按键 | 动作 |
|---|---|
| *打字* | 过滤历史(搜索框常驻聚焦) |
| `←` / `→` | 切换选中卡片 |
| `⌘←` / `⌘→` | 按屏翻页 |
| `回车` | 粘贴选中项 |
| `空格` | 快速预览选中卡片的气泡 |
| `⌦` / `⌘⌫` | 删除选中卡片 |
| `⌘Z` | 恢复刚删除的内容(搜索框为空时) |
| `Esc` | 收起预览 → 清空搜索 → 关闭面板 |

鼠标:左键点菜单栏图标打开或关闭面板,右键打开菜单。悬停卡片出现 **✎ 重命名**按钮;右键卡片 **复制 / 预览 / 重命名 / 置顶 / 收藏到 / 删除**。把卡片拖出可将内容拖放进其它 App。

## 安装

从 [Releases](https://github.com/yaoguohh/trove/releases) 页面下载最新的 `Trove.dmg`,
打开后把 `Trove.app` 拖进「应用程序」文件夹。

### 首次启动(重要)

Trove 目前**未经 Apple 公证**(暂无付费开发者账号),所以首次启动会被 macOS Gatekeeper 拦截。
这是**一次性**的:

1. 双击 `Trove.app`——macOS 提示「无法打开」。
2. 打开**系统设置 → 隐私与安全性**,滚到安全性区域,点 Trove 旁边的**「仍要打开」**,
   输入密码确认。

(终端方式:`xattr -dr com.apple.quarantine /Applications/Trove.app`)

放行这一次之后,**之后每次更新都会静默安装**——Sparkle 通过自己的连接下载更新、不带隔离属性,
Gatekeeper 不会再弹窗。

Trove 需要两项权限,缺任何一项时菜单栏菜单里会出现提示行:

- **辅助功能**(系统设置 → 隐私与安全性 → 辅助功能):把你选中的内容放进你原先所在的应用——
  能直接插入就直接插入,不行再模拟 `⌘V`。没有这项权限时,选中内容只会复制到剪贴板。
- **剪贴板访问**(macOS 15.4 起):在系统设置 → 隐私与安全性中把 Trove 设为**始终允许**,否则
  Trove 每次记录复制都会弹出询问;设为拒绝时什么都记不下来。菜单栏菜单里的「允许访问剪贴板…」
  会直接打开那一页。

## 隐私

所有内容都留在你的 Mac 上。

- **记录什么**:你复制的文本和图片,以及复制来源的应用名。标记为隐藏或临时的内容——密码管理器、
  文本扩展工具写的——在读取之前就被跳过。
- **存在哪里**:`~/Library/Application Support/Trove/`,包括 `history.json`,以及存图片和超大文本的
  `images/`、`texts/`。文件没有加密。删除一条内容后,它的文件会保留到撤销记录(25 次删除)
  翻过去为止;**清空历史**会一次删掉所有未置顶的内容及其文件。
- **联网**:只有两种情况。*检查更新*(Sparkle)向 GitHub 询问有没有新版本。*链接预览*默认关闭,
  打开后会抓取复制链接的网页标题和图标——请求前会去掉查询参数和锚点,但网站仍会知道这个链接被
  复制过;令牌在路径里的一次性链接可能因此失效。预览缓存在 `~/Library/Caches/Trove/`。
- **彻底清除**:退出 Trove,删掉 `~/Library/Application Support/Trove/` 和 `~/Library/Caches/Trove/`。

## 更新

Trove 会在后台自动检查更新,也可通过**菜单栏 →「检查更新…」**手动检查,基于 Sparkle 的
EdDSA 签名 appcast(独立于 Apple 公证)。

## 从源码构建

```bash
swift build
swift test
```

在本地跑出完整功能的方法见 [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md),代码组织见
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 打包签名 `.app`

```bash
bash scripts/package-app.sh        # → .build/Trove.app
```

环境变量(本地开发均可省略):

| 变量 | 用途 |
|---|---|
| `TROVE_SU_PUBLIC_KEY` | Sparkle EdDSA **公钥** → Info.plist 的 `SUPublicEDKey`(发布构建必需) |
| `TROVE_SU_FEED_URL` | appcast 地址 → `SUFeedURL`(默认指向最新 GitHub Release 里的 `appcast.xml`) |
| `TROVE_CODESIGN_IDENTITY` | 真实签名身份;不设置时用 ad-hoc 签名 |
| `TROVE_MARKETING_VERSION` / `TROVE_BUILD_VERSION` | 版本号与构建号;默认取最新标签加 `-dev` 和提交数 |

产物是通用二进制(Apple Silicon 与 Intel)。

## 发布

完整的维护者操作手册见 [RELEASE.md](RELEASE.md)(一次性 Sparkle 密钥设置、每次发布的
构建 → appcast → GitHub Release 步骤,以及绝不能破坏的硬约束)。

## 许可证

[MIT](LICENSE) © 2026 yaoguohh
