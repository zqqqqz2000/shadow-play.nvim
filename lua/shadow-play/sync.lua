---@type table<string, any>
local M = {}

---@type userdata
local uv = vim.uv or vim.loop -- 兼容 Neovim 0.9 和 0.10+

---@type userdata|nil
local server

---@type Config
local config

-- Get current tab information
---@return TabInfo[][]
local function get_tabs_info()
    ---@type TabInfo[][]
    local tabs = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        ---@type TabInfo[]
        local buffers = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            local buf = vim.api.nvim_win_get_buf(win)
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then
                ---@type TabInfo
                local tab_info = {
                    path = name,
                    active = vim.api.nvim_get_current_win() == win
                }
                table.insert(buffers, tab_info)
            end
        end
        if #buffers > 0 then
            table.insert(tabs, buffers)
        end
    end
    return tabs
end

-- Send message to VSCode/Cursor
---@param msg Message
---@param callback? function Called when message is sent
local function send_message(msg, callback)
    if not server then return end
    
    local client = uv.new_pipe()
    client:connect(config.socket_path, function()
        client:write(vim.json.encode(msg))
        client:shutdown()
        client:close()
        if callback then
            callback()
        end
    end)
end

-- Synchronize tab information
function M.sync_tabs()
    if not server then return end
    
    ---@type Message
    local msg = {
        type = "tabs",
        data = get_tabs_info()
    }
    
    send_message(msg)
end

-- Synchronize buffer changes
function M.sync_buffer()
    if not server then return end
    
    local current_buf = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(current_buf)
    
    ---@type Message
    local msg = {
        type = "buffer_change",
        data = {
            path = path
        }
    }
    
    send_message(msg)
end

-- Initialize sync service
---@param user_config Config
function M.init(user_config)
    config = user_config
    
    -- Create Unix domain socket server
    server = uv.new_pipe()
    
    -- Delete socket file if it exists
    if vim.fn.filereadable(config.socket_path) == 1 then
        vim.fn.delete(config.socket_path)
    end
    
    server:bind(config.socket_path)
    server:listen(128, function(err)
        if err then
            vim.notify("Shadow Play: Failed to start service: " .. err, vim.log.levels.ERROR)
            return
        end
        
        server:accept(function(client)
            client:read_start(function(err, chunk)
                if err then
                    vim.notify("Shadow Play: Failed to read data: " .. err, vim.log.levels.ERROR)
                    return
                end
                
                if chunk then
                    -- Handle messages from VSCode/Cursor
                    ---@type boolean, Message|string
                    local success, msg = pcall(vim.json.decode, chunk)
                    if success and type(msg) == "table" then
                        vim.schedule(function()
                            if msg.type == "tabs" then
                                -- TODO: Implement tab synchronization logic
                                ---@type TabInfo[][]
                                local tabs = msg.data
                                M.handle_tab_sync(tabs)
                            elseif msg.type == "buffer_change" then
                                -- Reload modified buffer
                                local bufnr = vim.fn.bufnr(msg.data.path)
                                if bufnr > 0 then
                                    vim.cmd("checktime " .. bufnr)
                                end
                            end
                        end)
                    end
                end
            end)
        end)
    end)
end

---Handle tab synchronization from VSCode/Cursor
---@param tabs TabInfo[][]
function M.handle_tab_sync(tabs)
    -- Get current tab pages
    local current_tabs = vim.api.nvim_list_tabpages()
    
    -- Create new tabs or update existing ones
    for i, tab_info in ipairs(tabs) do
        local tab = current_tabs[i]
        if not tab then
            -- Create new tab
            vim.cmd("tabnew")
            tab = vim.api.nvim_get_current_tabpage()
        end
        
        -- Get windows in current tab
        local wins = vim.api.nvim_tabpage_list_wins(tab)
        
        -- Update or create windows for each buffer
        for j, buf_info in ipairs(tab_info) do
            local win = wins[j]
            if not win then
                -- Create new window if needed
                vim.cmd("vsplit")
                win = vim.api.nvim_get_current_win()
            end
            
            -- Open or switch to buffer
            vim.api.nvim_win_set_buf(win, vim.fn.bufnr(buf_info.path, true))
            
            -- Activate window if needed
            if buf_info.active then
                vim.api.nvim_set_current_win(win)
            end
        end
        
        -- Close extra windows
        for j = #tab_info + 1, #wins do
            vim.api.nvim_win_close(wins[j], true)
        end
    end
    
    -- Close extra tabs
    for i = #tabs + 1, #current_tabs do
        vim.cmd("tabclose " .. i)
    end
end

return M 