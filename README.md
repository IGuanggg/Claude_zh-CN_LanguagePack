# Claude Desktop 简体中文语言包（Squirrel 版）

为 Windows 上通过 Squirrel/用户目录方式安装的 Claude Desktop 添加简体中文语言包，并在语言菜单中注册 `zh-CN` 选项。

本版本适配类似下面的安装路径：

```text
%LOCALAPPDATA%\AnthropicClaude\app-*\resources
```

如果你的 Claude 安装在自定义位置，可以先设置 `CLAUDE_INSTALL_DIR`，让脚本指向包含 `resources` 文件夹的 Claude app 目录。

## 快速使用

1. 关闭 Claude Desktop。
2. 双击 `安装中文语言包.bat`。
3. 等待脚本完成并自动重启 Claude。
4. 进入 Claude 左下角账号菜单，打开 `Settings` -> `Language`，选择中文。

如需恢复英文，双击 `卸载中文语言包.bat`。

## 脚本会做什么

- 写入桌面外壳翻译：`resources\zh-CN.json`
- 写入主界面翻译：`resources\ion-dist\i18n\zh-CN.json`
- 写入 Statsig 翻译：`resources\ion-dist\i18n\statsig\zh-CN.json`
- 修改 `ion-dist\assets\v1\index-*.js` 中的语言白名单，加入 `"zh-CN"`
- 将 `%APPDATA%\Claude\config.json` 中的 `locale` 设置为 `zh-CN`
- 安装前会为被修改的文件创建 `.bak` 备份
- 如果本地缺少翻译 JSON，脚本会自动从上游项目下载。

## 命令行用法

```powershell
# 安装中文语言包
powershell -NoProfile -ExecutionPolicy Bypass -File .\LanguagePack.ps1

# 卸载并恢复英文
powershell -NoProfile -ExecutionPolicy Bypass -File .\LanguagePack.ps1 -Restore
```

## 注意事项

- Claude 更新后可能覆盖 `resources` 目录，届时重新运行安装脚本即可。
- 如果语言菜单仍未出现中文，请完全退出 Claude 后重新运行安装脚本。
- 本项目仅用于个人学习与本地界面汉化，不属于 Anthropic 官方项目。

## 常见问题

### 提示 `Claude install directory was not found`

这个错误通常表示当前电脑没有安装经典 Squirrel 版 Claude Desktop，或 Claude 安装在脚本未能自动发现的位置。

脚本会自动从以下来源查找 Claude：

- 正在运行的 `claude.exe` 进程
- 开始菜单和桌面中的 Claude 快捷方式
- Windows 卸载注册表中的 Claude 安装信息
- `claude.exe` 命令路径
- 常见安装目录和限深目录扫描

```text
%LOCALAPPDATA%\AnthropicClaude
%LOCALAPPDATA%\Programs\Claude
%ProgramFiles%\Claude
%ProgramFiles(x86)%\Claude
```

如果你知道 Claude 的实际位置，可以在命令行中这样运行：

```powershell
$env:CLAUDE_INSTALL_DIR="D:\Your\Claude\app-0.0.0"
powershell -NoProfile -ExecutionPolicy Bypass -File .\LanguagePack.ps1
```

### 检测到 `MSIX/Store Claude installation`

新版 Claude 在部分 Windows 环境中会以 MSIX/Store 包形式安装，安装包资源通常位于 `C:\Program Files\WindowsApps\Claude_*`，应用数据位于 `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc`。

这类安装包的程序资源受 Windows 保护，本语言包不能直接修改 `WindowsApps` 目录。脚本会自动把 MSIX 包里的 Claude app 复制到下面的用户可写目录，再对这个副本安装中文语言包：

```text
%LOCALAPPDATA%\ClaudeChinesePack\MSIXCopy\app-*
```

安装完成后，脚本会创建 `Claude Chinese` 桌面快捷方式和开始菜单快捷方式。之后请使用这个快捷方式启动中文版本；如果继续打开系统原来的 Claude 快捷方式，启动的仍然是受保护的 MSIX 原版。

MSIX 版的用户配置仍然保留在原来的包数据目录中：

```text
%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude
```

脚本不会再把这份配置搬到 `%APPDATA%\Claude`。安装完成后生成的 `Claude Chinese` 启动器会临时设置 `APPDATA` / `LOCALAPPDATA`，让可写副本继续读取原 MSIX 配置目录。因此账号、历史记录、偏好设置会跟原 Claude 保持一致。

如果你之前运行旧版脚本后感觉配置变空，原配置通常仍在上面的 MSIX 数据目录中。更新脚本后重新运行一次，并使用新生成的 `Claude Chinese` 快捷方式启动即可。

如果 Claude 更新后中文失效，重新运行安装脚本即可。脚本会按新版本重新复制并打补丁。

## 鸣谢与授权

翻译文件基于 `pheohu-42/Claude_zh-CN_LanguagePack` 项目整理：

https://github.com/pheohu-42/Claude_zh-CN_LanguagePack

原项目采用 CC BY-NC-SA 4.0 授权。本项目保留相同授权要求：仅限非商业使用，转载或修改需署名，并以相同协议共享。
