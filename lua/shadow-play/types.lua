---@meta

---@class Config
---@field auto_reload boolean Whether to automatically reload files after modifications
---@field sync_interval number Synchronization interval in milliseconds
---@field socket_path string Unix domain socket path for communication between Neovim and VSCode (default: $XDG_DATA_HOME/shadow-play.sock)
---@field debug boolean Enable debug logging
---@field log_file string Path to the log file

---@class TabInfo
---@field path string File path
---@field active boolean Whether this is the active window
---@field viewState ViewState|nil View state information

---@class WindowLayout
---@field type "leaf"|"vsplit"|"hsplit" 布局类型：叶子节点（单个窗口）或分割类型
---@field buffers TabInfo[] 当前窗口包含的缓冲区（仅当type为leaf时有效）
---@field children WindowLayout[] 子窗口布局（仅当type为vsplit或hsplit时有效）
---@field size number|nil 分割比例（0-1之间的数字，可选）

---@class Message
---@field type "editor_group"|"buffer_change"|"view_change" Message type
---@field data WindowLayout|{ path: string, viewState: ViewState|nil } Message data
---@field from_nvim boolean Whether the message is from the nvim side plugin

---@class Buffer
---@field id number Buffer number
---@field name string Buffer name
---@field active boolean Whether this buffer is active

---@class Window
---@field id number Window ID
---@field buffer Buffer Associated buffer
---@field active boolean Whether this window is active

---@class Tab
---@field id number Tab page number
---@field windows Window[] Windows in this tab
---@field active boolean Whether this is the active tab

---@class Position
---@field line number
---@field character number

---@class ViewState
---@field cursor Position
---@field scroll { topLine: number, bottomLine: number } 