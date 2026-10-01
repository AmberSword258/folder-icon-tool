# 贡献者

## 主要作者

| 贡献者 | 说明 |
|---|---|
| [@AmberSword258](https://github.com/AmberSword258) | 项目作者，全部代码与文档 |

## 如何参与

欢迎提交 Issue 和 Pull Request。

由于这个工具是 **Windows PowerShell 5.1 + WinForms** 的桌面应用，
贡献代码前请先读 [README 的「开发」一节](README.md#开发)，特别注意两点：

1. `.ps1` 文件**必须带 UTF-8 BOM** —— 否则 Windows PowerShell 5.1 会按 ANSI
   解析，中文全部乱码并直接语法报错
2. **用 Windows PowerShell 5.1 验证，不要用 PowerShell 7（`pwsh`）** ——
   本项目面向 .NET Framework，PS7 下 `Add-Type` 行为不同，跑出来的失败
   与真实用户环境无关

这两条 CI 里都有自动检查，提交前在本地跑一遍能省不少往返：

```powershell
# 语法检查
$e=$null; $t=$null
[System.Management.Automation.Language.Parser]::ParseFile(
    "$PWD\FolderIconTool.ps1", [ref]$t, [ref]$e); $e

# 界面自检（构建界面 → 扫描 → 分析 → 测试各种图标来源 → 关闭）
.\FolderIconTool.ps1 -SelfTest
```
