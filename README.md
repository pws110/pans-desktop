# Pan's Desktop

一个透明的 macOS 桌面文件分区工具。当前版本：1.0.0（Build 53）。Swift / SwiftUI / AppKit 编写，无第三方依赖，MIT 许可。

## 下载与安装

1. 从 [Releases 发布页](https://github.com/pws110/pans-desktop/releases/latest) 下载 `PansDesktop-v1.0.0-build53-macOS-arm64.zip`，解压。
2. 把整个“Pan's Desktop”文件夹放到你有读写权限的位置，例如个人“文稿”或 `~/Applications/Pan's Desktop`。**保留外层文件夹，不要只把 app 放到系统 `/Applications` 根目录。**
3. 打开文件夹里的“Pan's Desktop.app”。首次启动会创建新的默认分区。
4. 每个分区右上角“…”菜单可设置“拖入方式”。想保留原文件位置，选“仅添加引用（原路径不变）”；“收纳文件”模式会移动文件到软件旁边的收纳文件夹。

当前下载包为 **Apple Silicon（M 系列）** 版本，最低构建目标为 macOS 14；实际开发和验收在当前开发电脑完成，未逐一验证所有 macOS 版本。Intel Mac 需要另行编译和验收。

软件只有本地临时签名，**没有 Apple Developer ID 签名或苹果公证**，在另一台 Mac 下载后可能被系统拦截。请核对来源和 SHA256，不要关闭系统安全保护；也可以从本仓库源码在自己的 Mac 上编译。系统对下载软件的处理参见 [Apple 官方说明](https://support.apple.com/en-us/102445)。

## 功能

- 透明桌面分区，独立锁定、拖动位置、按内容原地放大及还原。
- 分区独立收起/展开，文件名搜索，文件网格排列。
- 支持文档、图片、文件夹；每区可选引用或收纳。
- 解锁后支持区内排序、跨区拖放、移入文件夹。
- 打开文档后分区留在桌面层；放大分区优先显示在其他分区前。
- 文件和分区相关操作的具体保护规则以当前源码为准。

## 保存与备份

运行时数据存放在 app **旁边的外层文件夹**，包括 `Configuration`、`收纳文件` 和 `TestFiles`。更新软件前先退出软件，备份整个外层文件夹，再只替换 app。

本仓库和下载包只含软件、源码、合成测试代码及说明，**不含个人文档、图片、分区配置、原文件路径清单或操作日志**。

分区里的“引用”仍依赖原文件。仅复制软件到别的电脑不会同步那些文档，旧电脑上的绝对路径也不能直接当作新电脑路径使用。需要迁移个人数据时，请另做自己的完整备份；不要把它们直接提交到本仓库。

## 从源码构建

安装 Xcode 或 Apple Command Line Tools。执行：

```sh
./scripts/build.sh
```

默认输出在 `_build.noindex/`，不会安装、启动软件或改动现有分区。可通过 `MACOS_SDK` 指定与 Swift 编译器匹配的 SDK，例如：

```sh
MACOS_SDK=/path/to/MacOSX.sdk ./scripts/build.sh
```

默认 `arm64`；在 Intel 开发机上可使用 `ARCH=x86_64`，但此仓库保存的发行包未做 Intel 实机验收。

模型和存储的基础测试只使用新建临时文件：

```sh
./scripts/test-model.sh
```

其他原生交互测试保留在 `Tests/`，个别测试有显式真实桌面参数；不会在构建脚本中自动运行。

## 发布

源码提交 GitHub 仓库，软件 ZIP 和 `SHA256SUMS.txt` 放到同一版本的 Releases。GitHub Releases 支持版本说明与二进制下载，参见 [GitHub 官方说明](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)。

软件备份保留为 ZIP；编译和验收的展开副本放在不参与系统搜索的目录，避免系统“应用”列表出现多个同名入口。
