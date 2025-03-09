---@type table<string, any>
local M = {}

-- Default configuration
---@type Config
local default_config = {
    auto_reload = true,
    sync_interval = 1000, -- Synchronization interval (milliseconds)
    socket_path = vim.fn.stdpath("data") .. "/shadow-play.sock"
}

---@type Config
local config = default_config

---Initialize the plugin with user configuration
---@param user_config Config|nil
function M.setup(user_config)
    -- Merge user configuration
    ---@type Config
    config = vim.tbl_deep_extend("force", default_config, user_config or {})
    
    -- Create autocommand group
    local group = vim.api.nvim_create_augroup("ShadowPlay", { clear = true })
    
    -- Watch for tab changes
    vim.api.nvim_create_autocmd({"BufAdd", "BufDelete", "BufEnter"}, {
        group = group,
        callback = function()
            require("shadow-play.sync").sync_tabs()
        end,
    })
    
    -- Watch for file modifications
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = group,
        callback = function()
            require("shadow-play.sync").sync_buffer()
        end,
    })
    
    -- Initialize sync service
    require("shadow-play.sync").init(config)
end

return M 