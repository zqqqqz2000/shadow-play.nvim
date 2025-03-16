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
---@field type "leaf"|"vsplit"|"hsplit"|"auto" Layout type: leaf node (single window) or split type
---@field buffers TabInfo[] Buffers in the current window (only valid when type is leaf)
---@field children WindowLayout[] Child window layouts (only valid when type is vsplit or hsplit)
---@field size number|nil Split ratio (number between 0-1, optional)

---@class Message
---@field type "editor_group"|"buffer_change" Message type
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