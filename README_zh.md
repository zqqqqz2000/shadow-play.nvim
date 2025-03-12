# Shadow Play

> ⚠️ **项目状态**: 开发中 - 本项目正在积极开发中，尚未准备好用于生产环境。功能和 API 可能会随时更改，恕不另行通知。

[English](README.md) | [中文](README_zh.md)

Shadow Play 是一个强大的编辑器集成插件，让你可以在 VSCode/Cursor 中使用 Neovim 作为嵌入式的 Zen-mode 编辑器。与 VSCode 的 Neovim 插件不同，这是一个真正运行在终端中的 Neovim 实例，为你提供完整、原汁原味的 Neovim 体验。你可以在 Neovim 和 VSCode/Cursor 之间无缝切换，无需额外的终端窗口，同时保持完美的编辑状态同步。

## ✨ 功能特性

- 在 VSCode/Cursor 中使用 Neovim 作为嵌入式的 Zen-mode 编辑器
- 在 Neovim 和 VSCode 编辑模式之间无缝切换
- 无需额外的终端窗口来运行 Neovim
- 实时同步打开的标签页
- 同步标签页顺序
- 同步当前选中的标签页
- 文件修改后自动重新加载
- 支持同一台机器上的 VSCode/Cursor 和 Neovim 之间的同步

## 🚀 安装

### Neovim 插件安装

使用你喜欢的插件管理器安装，例如使用 [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "zqqqqz2000/shadow-play.nvim",
    event = "VeryLazy",
    config = function()
        require("shadow-play").setup()
    end
}
```

### VSCode/Cursor 插件安装

1. 打开 VSCode/Cursor
2. 按下 `Ctrl+P` 打开命令面板
3. 输入 `ext install shadow-play`
4. 点击安装

## ⚙️ 配置

### Neovim 配置

```lua
require("shadow-play").setup({
    -- 配置选项
    auto_reload = true,      -- 文件修改后自动重新加载
    sync_interval = 1000,    -- 同步间隔（毫秒）
    socket_path = vim.fn.stdpath("data") .. "/shadow-play.sock",  -- Unix domain socket 路径
    debug = false,           -- 是否启用调试日志
    log_file = vim.fn.stdpath("cache") .. "/shadow-play.log"      -- 日志文件路径
})
```

### VSCode/Cursor 配置

在设置中搜索 "Shadow Play" 进行相关配置：

- `shadowPlay.autoReload`: 文件修改后是否自动重新加载
- `shadowPlay.syncInterval`: 同步间隔（毫秒）
- `shadowPlay.socketPath`: Unix domain socket 路径，**必须与 Neovim 配置中的 socket_path 保持一致**

#### Socket 路径配置说明

`socket_path` 是 Neovim 和 VSCode/Cursor 之间通信的关键配置项。默认配置：

- Neovim: `~/.local/share/nvim/shadow-play.sock`（Linux/macOS）
- VSCode/Cursor: 需要配置相同的路径

注意事项：
1. 两边的 `socket_path` 必须配置相同的路径
2. 该路径必须对两个编辑器都有读写权限
3. 如果修改了默认路径，请确保新路径所在目录存在且有正确的权限

## 🔧 使用方法

插件安装完成后会自动在后台运行，无需额外操作。当你在任一编辑器中：

- 打开新文件
- 关闭文件
- 调整标签页顺序
- 切换当前标签页
- 修改文件内容

这些操作都会自动同步到另一个编辑器中。

## 🐛 故障排除

如果遇到同步问题，可以：

1. 检查 socket 文件是否存在：
```bash
ls -l ~/.local/share/nvim/shadow-play.sock
```

2. 确保两个编辑器都能访问 socket 文件：
```bash
# 检查权限
ls -la ~/.local/share/nvim/
```

3. 如果问题持续，可以尝试删除 socket 文件并重启编辑器：
```bash
rm ~/.local/share/nvim/shadow-play.sock
```

## 🤝 贡献

欢迎提交 Pull Request 或创建 Issue！

## 📝 许可证

MIT

## 🙏 致谢

感谢所有贡献者的支持！ 