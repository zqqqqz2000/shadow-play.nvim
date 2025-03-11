-- Add current directory to runtimepath for development
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local shadow_play = require("shadow-play")

-- Debug configuration
local config = {
    -- Enable debug mode for detailed logging
    debug = true,
    -- Log file path (relative to current directory for development)
    log_file = "shadow-play.log",
    -- Unix domain socket path for IPC
    socket_path = "/tmp/shadow-play.sock"
}

-- Initialize plugin with debug configuration
shadow_play.setup(config)

-- Debug Commands
vim.api.nvim_create_user_command("ShadowPlaySync", function()
    require("shadow-play.sync").sync_tabs()
end, {
    desc = "Manually trigger tab synchronization"
})

vim.api.nvim_create_user_command("ShadowPlayStatus", function()
    -- Display detailed information about current tabs and windows
    local tabs = vim.api.nvim_list_tabpages()
    for _, tab in ipairs(tabs) do
        local tab_num = vim.api.nvim_tabpage_get_number(tab)
        print(string.format("Tab %d:", tab_num))
        
        local wins = vim.api.nvim_tabpage_list_wins(tab)
        for _, win in ipairs(wins) do
            local buf = vim.api.nvim_win_get_buf(win)
            local name = vim.api.nvim_buf_get_name(buf)
            local win_num = vim.api.nvim_win_get_number(win)
            local buftype = vim.bo[buf].buftype
            print(string.format("  Window %d:", win_num))
            print(string.format("    Buffer: %s", name ~= "" and name or "[No Name]"))
            print(string.format("    Type: %s", buftype ~= "" and buftype or "normal"))
        end
    end
end, {
    desc = "Display detailed window and tab information"
})

-- Print startup message
print("Shadow Play debug environment initialized")
print("Available commands:")
print("  :ShadowPlaySync  - Manually trigger tab synchronization")
print("  :ShadowPlayStatus - Display current window and tab information")
print(string.format("Log file: %s", config.log_file)) 