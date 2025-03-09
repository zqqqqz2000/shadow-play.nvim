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
    "zqqqqz2000/shadow-play.nvim",
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
    auto_reload = true,      -- Auto reload files after modifications
    sync_interval = 1000,    -- Sync interval in milliseconds
    socket_path = vim.fn.stdpath("data") .. "/shadow-play.sock",  -- Unix domain socket path
    debug = false,           -- Enable debug logging
    log_file = vim.fn.stdpath("cache") .. "/shadow-play.log"      -- Log file path
})
```

### VSCode/Cursor Configuration

Search for "Shadow Play" in settings:

- `shadowPlay.autoReload`: Auto reload files after modifications
- `shadowPlay.syncInterval`: Sync interval in milliseconds
- `shadowPlay.socketPath`: Unix domain socket path, **must match the socket_path in Neovim configuration**

#### Socket Path Configuration

The `socket_path` is a crucial configuration for communication between Neovim and VSCode/Cursor. Default configuration:

- Neovim: `~/.local/share/nvim/shadow-play.sock` (Linux/macOS)
- VSCode/Cursor: Must be configured with the same path

Important notes:
1. The `socket_path` must be configured with the same path on both sides
2. Both editors must have read and write permissions to this path
3. If you modify the default path, ensure the new directory exists and has correct permissions

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