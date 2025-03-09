# Shadow Play

[English](README.md) | [中文](README_zh.md)

Shadow Play is a powerful editor synchronization plugin that enables real-time tab state synchronization between VSCode/Cursor and Neovim.

## ✨ Features

- Real-time synchronization of open tabs
- Synchronization of tab order
- Synchronization of active tab selection
- Automatic reload after file modifications
- Support for VSCode/Cursor and Neovim synchronization on the same machine

## 🚀 Installation

### Neovim Plugin Installation

Install using your favorite plugin manager, for example with [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
    "username/shadow-play.nvim",
    event = "VeryLazy",
    config = function()
        require("shadow-play").setup()
    end
}
```

### VSCode/Cursor Plugin Installation

1. Open VSCode/Cursor
2. Press `Ctrl+P` to open command palette
3. Type `ext install shadow-play`
4. Click install

## ⚙️ Configuration

### Neovim Configuration

```lua
require("shadow-play").setup({
    -- Configuration options
})
```

### VSCode/Cursor Configuration

Search for "Shadow Play" in settings to configure the plugin.

## 🔧 Usage

The plugin runs automatically in the background after installation. When you:

- Open new files
- Close files
- Reorder tabs
- Switch active tabs
- Modify file contents

These operations will automatically sync to the other editor.

## 🤝 Contributing

Pull Requests and Issues are welcome!

## 📝 License

MIT

## 🙏 Acknowledgments

Thanks to all contributors! 