# Pan's Desktop 1.0.0 · Build 77

## 中文

- 单列最窄分区的“…”下拉菜单独立展开，主菜单及子菜单完整显示文字，保留“…”按钮。
- 透明放大图标及完整文件名，长名称自动向下换行；相邻文件保持显示，鼠标经过展开文字不会激活下方文件。
- 图标下方只显示名称；81 × 81 点网格、横纵均为 3 点间距，普通图标保持 44 × 42 点。
- 点击分区隐藏其他可见应用；再次点击分区空白处恢复本次隐藏的应用。程序和文档继续运行，分区固定原位。
- 所有分区可缩到一列；窄分区的收起、放大和锁定操作放入更多菜单。

## English

Full-width native More menus and submenus now display complete command text even in one-column partitions. This release also includes transparent full-filename hover, visible neighboring icons, compact equal grid gaps, filenames without metadata, fixed partition positions, and hide/restore of other application windows.

## 下载 / Downloads

- `PansDesktop-v1.0.0-build77-macOS-arm64.zip`: Apple Silicon 软件包 / application.
- `PansDesktop-source-build77.zip`: 源码、图标、测试和中英文说明 / source, assets, tests, and bilingual documentation.
- `SHA256SUMS.txt`: 下载校验 / checksums.

解压后保留整个 “Pan's Desktop” 外层文件夹，放到可读写位置，再打开其中的 app。更新前备份原外层文件夹，仅替换 app，保留 Configuration 和收纳文件。此公开便携包不含本机安装专用的数据目录连接。

Keep the entire outer folder in a writable location. Back up an existing installation's outer folder before replacing only the app. Preserve its Configuration and stored files. This portable release contains no machine-specific data-location bookmark.

最低构建目标 macOS 14，Apple Silicon；未逐一验证所有系统版本。软件仅本地签名，没有 Apple Developer ID 签名或苹果公证。Minimum target: macOS 14 on Apple Silicon. Locally signed; not Apple-notarized. Not all macOS versions have been tested.

## 验证 / Validation

91 项隔离原生检查通过，涵盖悬停、桌面回调、一列最小宽度和完整菜单。实际观测：分区宽 116 点，独立菜单宽 222 点。显示桌面的实际系统往返行为在 Build 74 验证过，后续保留该逻辑；不是对所有第三方应用的兼容保证。其他历史测试未作为本次通过声明。

91 isolated native checks passed. The observed native menu was 222 points wide beside a 116-point partition. Live hide/restore was verified in Build 74; later builds preserve that logic. Other historical test suites are not claimed as passing in this release.

仅含软件和源码，不含个人文件、分区配置、操作日志、私人路径或数据位置连接。Only clean software and source are included; no personal files, partition settings, activity logs, private paths, or data-location bookmark.
