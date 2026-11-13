# 0001 免费分发：ad-hoc 签名、不公证、Sparkle 自动更新

- 状态：已采纳
- 日期：2026-06-03（发布流程）；2026-06-13（改名 Trove，定下 bundle id）
- 依据：`2fce068`、`62a61b3`、`4258fc2`、`1d59826`；本分支 `38b4c50`、`2b7eee9`

## 背景

Trove 没有付费的 Apple 开发者账号，不能用 Developer ID 签名和公证，但仍需要可靠的自动更新。

## 决定

- 应用用 ad-hoc 签名，并把 designated requirement 固定为 `identifier "io.github.yaoguohh.trove"`。
  这样每次构建的签名身份相同：Sparkle 的签名一致性检查能通过，macOS 也会保留辅助功能授权。
- 自动更新用 Sparkle 的 EdDSA 签名 appcast，与 Apple 公证无关。appcast 作为 GitHub Release 的附件发布，
  `SUFeedURL` 指向 `releases/latest/download/appcast.xml`，不提交进仓库。
- 产物是 dmg，内含通用二进制（Apple Silicon 与 Intel），最低 macOS 14。
- 正式发版只通过推送标签触发 CI；构建号取 CI 的 `run_number`。
- 本地打包默认也用 ad-hoc 签名，只有显式设置 `TROVE_CODESIGN_IDENTITY` 才换证书。

不可改动的硬约束（bundle id、designated requirement、`SUPublicEDKey`、不开 Hardened Runtime、不用
`codesign --deep`）列在 `RELEASE.md`。

## 放弃的方案

- **Developer ID 签名 + 公证**：需要每年付费账号。好处是首次启动不需要在系统设置里"仍要打开"。
- **把 appcast 提交到仓库**：每次发版要回写主分支；Release 附件的固定地址做到了同样的事。

## 后果

用户首次启动需要手动放行一次；之后的更新由 Sparkle 静默安装。改 bundle id 或签名方式会让已安装的用户
收不到更新、并丢失辅助功能授权。

## 什么时候重新考虑

开通 Apple 开发者账号时：改用 Developer ID 签名并公证（可以加 Hardened Runtime），designated
requirement 随之变化，需要一次过渡版本。
