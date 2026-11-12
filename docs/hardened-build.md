# Breeze 加固版桌面构建

从本仓库的 [Hardened Desktop Build](https://github.com/SHD-ISAC/B/actions/workflows/hardened_desktop.yml) 选择一次成功的运行，再下载相应平台的产物。

| 平台 | 产物名称 | 安装包 |
| --- | --- | --- |
| macOS（Apple 芯片） | `Breeze-Hardened-macOS-arm64` | `Breeze-Hardened-macOS-*-arm64.dmg` |
| Linux（x86_64） | `Breeze-Hardened-Linux-x64` | `breeze_*_amd64.deb` |

解压 GitHub Actions 下载的 ZIP，然后在解压目录中验证安装包。以 macOS 为例，使用 GitHub CLI 验证构建来源。

```sh
shasum -a 256 -c SHA256SUMS
gh attestation verify Breeze-Hardened-macOS-*-arm64.dmg \
  --repo SHD-ISAC/B \
  --signer-workflow SHD-ISAC/B/.github/workflows/hardened_desktop.yml
```

Linux 下可以运行 `sha256sum -c SHA256SUMS`，并把来源验证命令中的 DMG 文件名换成 `.deb` 文件名。

验证通过后，挂载 DMG，将 `Breeze.app` 拖到「应用程序」。应用使用临时签名（ad hoc），未进行 Apple 公证。若系统拦截首次启动，可在「系统设置 → 隐私与安全性」中单独允许打开。后续版本从本仓库的 Actions 下载。
