---@meta

---@class Config
---@field auto_reload boolean Whether to automatically reload files after modifications
---@field sync_interval number Synchronization interval in milliseconds
---@field socket_path string Unix domain socket path

---@class TabInfo
---@field path string File path
---@field active boolean Whether this is the active window

---@class Message
---@field type "tabs"|"buffer_change" Message type
---@field data TabInfo[][]|{path: string} Message data

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