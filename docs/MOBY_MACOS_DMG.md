# Kiri Moby 原生 macOS 安装（DMG）

日常安装不再需要执行 shell 脚本。

1. 从 GitHub Actions 下载安装产物 `Kiri-Moby-macos-arm64-DMG`。
2. 解压 Actions 下载的 ZIP，双击其中的 `Kiri-Moby-macos-arm64.dmg`。
3. Finder 会显示 `Kiri Moby.app` 和 `Applications` 快捷入口。将 App 拖到 Applications。
4. 从「应用程序」启动 Kiri Moby，第一次运行会自动在自己的用户目录初始化 Linux Guest / Docker Engine；不需要手动初始化磁盘或 Docker Socket。
5. 升级时先在 Kiri 界面停止 VM，再把新版 App 拖到 Applications 并选择替换。Docker 数据盘 `~/.kiri-moby/vm/data.img` 独立保存，不随 App 删除。

GitHub Actions 现在额外生成：

- **主要产物：** `Kiri-Moby-macos-arm64-DMG`（内部为 `.dmg` 与 `.dmg.sha256`）。
- 兼容旧流程：`Kiri-Moby-macos-arm64-app`（`.tgz` / `.sh`），不是日常安装必需。
- 当配置 Developer ID 与 notarization 凭据时：`Kiri-Moby-macos-arm64-DeveloperID-notarized`（同样具有拖拽安装布局）。

## 本机使用、首次允许与后续更新

没有 Developer ID 证书时，程序只能使用 Ad-hoc 签名。**DMG 是安装形式，不是受信任的开发者签名。**

第一次下载、安装时，macOS 可能要求在「系统设置 → 隐私与安全性」确认打开。
而新下载的每个 Ad-hoc 版本仍有可能重复触发 Gatekeeper。**不能承诺“拖拽一次并授权后，所有未来从 Internet 下载的 DMG 都无需再批准”。**

以前的 `Kiri-Moby-install-local.sh` 仍可选用于用户明确选择的个人开发版持续更新；该工具通过一次授权及限定范围的隔离标记处理来避免每次手动放行，但它不是默认安装方式。更彻底的无提示更新仍需要正式 Developer ID 与 Apple 公证，或者后续独立开发应用内受控更新机制。

绝不全局停用 Gatekeeper，也不自动修改其他应用的隔离属性。

## CI 验证

`scripts/moby/package-dmg-macos.sh` 会验证打包前的代码签名、Bundle ID；
使用 `ditto` 拷贝完整 App 并创建 `/Applications` 符号链接；
使用 `hdiutil create` 生成只读压缩 DMG，并用 `hdiutil verify` 验证磁盘镜像、用 `shasum` 输出 SHA256。

真实 Apple Silicon 设备上的 Finder 拖拽、首次 Gatekeeper 授权及启动需要实际验收。

Apple 官方说明：
https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution
