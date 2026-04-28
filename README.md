# Claude Desktop 简体中文语言包（Squirrel 版）

为 Windows 上通过 Squirrel/用户目录方式安装的 Claude Desktop 添加简体中文语言包，并在语言菜单中注册 `zh-CN` 选项。

本版本适配类似下面的安装路径：

```text
%LOCALAPPDATA%\AnthropicClaude\app-*\resources
```

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

## 鸣谢与授权

翻译文件基于 `pheohu-42/Claude_zh-CN_LanguagePack` 项目整理：

https://github.com/pheohu-42/Claude_zh-CN_LanguagePack

原项目采用 CC BY-NC-SA 4.0 授权。本项目保留相同授权要求：仅限非商业使用，转载或修改需署名，并以相同协议共享。
