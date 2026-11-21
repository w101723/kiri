# Kiri Moby：macOS 原生安装与个人开发版更新

**默认安装方式已经改为标准 DMG：** 下载 GitHub Actions
`Kiri-Moby-macos-arm64-DMG`，解压 ZIP 并双击 DMG，在 Finder 中将
`Kiri Moby.app` 拖到 `Applications` 即可。**首次安装不再需要运行 .sh。**

正式构建将原有 Swift `kiri-moby-host` 封装为
`Kiri Moby.app/Contents/Library/Helpers/Kiri Moby Helper.app`。
Helper 独立签名，名称为 **Kiri Moby Helper**，不显示 Dock 图标；
原本由 macOS 启动的 Virtualization XPC 虚拟机服务仍会单独存在。
安装器验证嵌套 App 的 bundle ID、ARM64 架构和签名。
具体参见 `docs/MOBY_MACOS_DMG.md`。

下文是仅在你希望对未来的 Ad-hoc 开发版进行“一次明确授权、以后少弹 Gatekeeper”
时使用的**可选旧方案**，不再是默认安装步骤。

不必加入 Apple Developer Program。正式公证流程仍保留，但对于你自己的 Kiri
开发版本，可以使用 **明确的一次性本机授权** + 专用安装脚本。

## 为什么手动“仍要打开”可能每版都弹

GitHub Actions 的开发版使用 `codesign --sign -` Ad-hoc 签名。
Gatekeeper 对从互联网下载且带有 quarantine 标记的每个新构建执行检查。
对旧构建点击一次“仍要打开”**不能保证**新构建自动继承。

## 使用方法

从你自己的 `w101723/kiri` 仓库 Actions 下载名为
`Kiri-Moby-macos-arm64-app` 的 ZIP。里面附带
`Kiri-Moby-install-local.sh`、`.tgz` 和 `.tgz.sha256`。

首次在 Mac 的终端执行（需要你亲自交互确认）：

```bash
bash Kiri-Moby-install-local.sh --trust-local-builds
```

按提示输入 `TRUST KIRI`。本机将在
`~/Library/Application Support/Kiri Moby/trust-local-builds-v1`
保存仅属于当前用户的授权标记（权限 0600）。

以后更新任何一个**由你信任的仓库构建并手动下载**的版本：

```bash
bash Kiri-Moby-install-local.sh ~/Downloads/Kiri-Moby-macos-arm64-app.zip
```

脚本默认安装/升级 `~/Applications/Kiri Moby.app`；不用 sudo。
如果你的应用原本在 `/Applications`，首次把它移到 `~/Applications`，
或在有写入权限时使用 `KIRI_MOBY_APP_PARENT=/Applications` 指向原路径。
升级前关闭 Kiri Moby VM。脚本保留旧 App 备份，不会触碰
`~/.kiri-moby/vm/data.img`，也不会更改 Docker Context、OrbStack。

另有只校验不安装的命令：

```bash
bash Kiri-Moby-install-local.sh --verify ~/Downloads/Kiri-Moby-macos-arm64-app.zip
bash Kiri-Moby-install-local.sh --status
bash Kiri-Moby-install-local.sh --revoke-local-trust
```

## 安全边界（重要）

此方案**不等于** Apple 官方签名或公证。用户一次同意后，
专用脚本会在每次升级前验证 `.tgz.sha256`、ARM64 架构、代码签名完整性、
Bundle ID `dev.kiri.app.moby` 和 Git 源代码版本标识，
然后**仅针对这一份 Kiri Moby.app 的暂存目录**移除
`com.apple.quarantine`，避免对后续每个开发版重复 Gatekeeper 人工放行。

这些校验不能证明发行者真实身份：攻击者如果能同时替换压缩包和校验和，
仍可能让恶意程序通过校验，因此必须只使用自己信任并检查来源的 GitHub 构建产物。
它不会执行 `spctl --master-disable`、不会处理整个 Downloads，也不会全局信任其他 App。

如果你以后直接从 ZIP 拖拽一个新的 App 而**不通过此安装脚本**，
仍可能再次弹出“仍要打开”。Mac 对文件访问、网络等系统权限的正常询问，
也不是此机制能免除的。

面向其他用户分发，应改用 `docs/MOBY_MACOS_SIGNING.md` 的
Developer ID + 公证方案。
