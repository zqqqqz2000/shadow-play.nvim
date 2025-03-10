---@type table<string, any>
local M = {}

---@type userdata
local uv = vim.uv or vim.loop -- Compatible with both Neovim 0.9 and 0.10+

---@type userdata|nil
local server

---@type Config
local config

-- Enhanced logging function
---@param msg string
---@param level number
local function log(msg, level)
    if not config or not config.debug then return end
    
    level = level or vim.log.levels.INFO
    local level_str = ({
        [vim.log.levels.DEBUG] = "DEBUG",
        [vim.log.levels.INFO] = "INFO",
        [vim.log.levels.WARN] = "WARN",
        [vim.log.levels.ERROR] = "ERROR"
    })[level] or "INFO"
    
    local log_msg = string.format("[%s][%s] %s", 
        os.date("%Y-%m-%d %H:%M:%S"),
        level_str,
        msg
    )
    
    -- Output to Neovim notification system
    vim.notify(log_msg, level)
    
    -- Write to log file
    if config.log_file then
        local file = io.open(config.log_file, "a")
        if file then
            file:write(log_msg .. "\n")
            file:close()
        end
    end
end

-- Get current tab information
---@return TabInfo[][]
local function get_tabs_info()
    log("Getting current tab information...", vim.log.levels.DEBUG)
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
                log(string.format("Found buffer: %s (active: %s)", name, tostring(tab_info.active)), vim.log.levels.DEBUG)
            end
        end
        if #buffers > 0 then
            table.insert(tabs, buffers)
        end
    end
    log(string.format("Found %d tabs with buffers", #tabs), vim.log.levels.DEBUG)
    return tabs
end

-- Send message to VSCode/Cursor
---@param msg Message
---@param callback? function Called when message is sent
local function send_message(msg, callback)
    if not server then 
        log("Server not initialized, cannot send message", vim.log.levels.WARN)
        return 
    end
    
    log(string.format("Sending message of type '%s'", msg.type), vim.log.levels.DEBUG)
    local client = uv.new_pipe()
    client:connect(config.socket_path, function()
        local json = vim.json.encode(msg)
        log(string.format("Sending data: %s", json), vim.log.levels.DEBUG)
        client:write(json)
        client:shutdown()
        client:close()
        log("Message sent successfully", vim.log.levels.DEBUG)
        if callback then
            callback()
        end
    end)
end

-- Synchronize tab information
function M.sync_tabs()
    if not server then return end
    log("Starting tab synchronization", vim.log.levels.INFO)
    
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
    log(string.format("Buffer changed: %s", path), vim.log.levels.INFO)
    
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
    log("Initializing Shadow Play sync service", vim.log.levels.INFO)
    
    -- Create Unix domain socket server
    server = uv.new_pipe()
    log(string.format("Using socket path: %s", config.socket_path), vim.log.levels.INFO)
    
    -- Delete socket file if it exists
    if vim.fn.filereadable(config.socket_path) == 1 then
        log("Removing existing socket file", vim.log.levels.DEBUG)
        vim.fn.delete(config.socket_path)
    end
    
    local ok, err = server:bind(config.socket_path)
    if not ok then
        log(string.format("Failed to bind socket: %s", err), vim.log.levels.ERROR)
        return
    end
    log("Socket bound successfully", vim.log.levels.DEBUG)
    
    server:listen(128, function(err)
        if err then
            log(string.format("Failed to start service: %s", err), vim.log.levels.ERROR)
            return
        end
        log("Server listening for connections", vim.log.levels.INFO)
        
        local client = uv.new_pipe()
        server:accept(client)
        log("New client connection accepted", vim.log.levels.DEBUG)
        
        client:read_start(function(err, chunk)
            if err then
                log(string.format("Failed to read data: %s", err), vim.log.levels.ERROR)
                client:close()
                return
            end
            
            if chunk then
                log(string.format("Received data: %s", chunk), vim.log.levels.DEBUG)
                -- Handle messages from VSCode/Cursor
                ---@type boolean, Message|string
                local success, msg = pcall(vim.json.decode, chunk)
                if success and type(msg) == "table" then
                    log(string.format("Processing message of type: %s", msg.type), vim.log.levels.DEBUG)
                    vim.schedule(function()
                        -- Handle message based on type
                        if msg.type == "tabs" then
                            log("Handling tab sync from VSCode", vim.log.levels.INFO)
                            M.handle_tab_sync(msg.data)
                        elseif msg.type == "buffer_change" then
                            log("Handling buffer change from VSCode", vim.log.levels.INFO)
                            -- Handle buffer change from VSCode
                            local path = msg.data.path
                            log(string.format("Reloading buffer: %s", path), vim.log.levels.DEBUG)
                            
                            -- Get the buffer number
                            local bufnr = vim.fn.bufnr(path)
                            if bufnr > 0 then
                                -- If buffer is loaded, reload it
                                log(string.format("Buffer found (bufnr: %d), reloading...", bufnr), vim.log.levels.DEBUG)
                                vim.cmd(string.format("checktime %d", bufnr))
                            else
                                -- If buffer doesn't exist, log warning and open it
                                log(string.format("Buffer not found for path: %s, opening it...", path), vim.log.levels.WARN)
                                vim.schedule(function()
                                    -- Open file in new buffer
                                    vim.cmd(string.format("edit %s", vim.fn.fnameescape(path)))
                                    -- Reload to ensure content is up-to-date
                                    vim.cmd("checktime")
                                end)
                            end
                        end
                    end)
                else
                    log("Failed to parse received message", vim.log.levels.WARN)
                end
            else
                log("Client disconnected", vim.log.levels.DEBUG)
                client:close()
            end
        end)
    end)
end

---Handle tab synchronization from VSCode/Cursor
---@param tabs TabInfo[][]
function M.handle_tab_sync(tabs)
    log(string.format("Starting tab sync with %d tabs", #tabs), vim.log.levels.INFO)
    
    -- Get current tab pages
    local current_tabs = vim.api.nvim_list_tabpages()
    log(string.format("Current Neovim tabs: %d", #current_tabs), vim.log.levels.DEBUG)
    
    -- Create new tabs or update existing ones
    for i, tab_info in ipairs(tabs) do
        local tab = current_tabs[i]
        if not tab then
            log(string.format("Creating new tab %d", i), vim.log.levels.DEBUG)
            vim.cmd("tabnew")
            tab = vim.api.nvim_get_current_tabpage()
        end
        
        -- Get windows in current tab
        local wins = vim.api.nvim_tabpage_list_wins(tab)
        
        -- Update or create windows for each buffer
        for j, buf_info in ipairs(tab_info) do
            local win = wins[j]
            if not win then
                log(string.format("Creating new window for buffer: %s", buf_info.path), vim.log.levels.DEBUG)
                vim.cmd("vsplit")
                win = vim.api.nvim_get_current_win()
            end
            
            -- Open or switch to buffer
            log(string.format("Setting buffer %s in window", buf_info.path), vim.log.levels.DEBUG)
            vim.api.nvim_win_set_buf(win, vim.fn.bufnr(buf_info.path, true))
            
            -- Activate window if needed
            if buf_info.active then
                log(string.format("Activating window for buffer: %s", buf_info.path), vim.log.levels.DEBUG)
                vim.api.nvim_set_current_win(win)
            end
        end
        
        -- Close extra windows
        for j = #tab_info + 1, #wins do
            log(string.format("Closing extra window %d in tab %d", j, i), vim.log.levels.DEBUG)
            vim.api.nvim_win_close(wins[j], true)
        end
    end
    
    -- Close extra tabs
    for i = #tabs + 1, #current_tabs do
        log(string.format("Closing extra tab %d", i), vim.log.levels.DEBUG)
        vim.cmd("tabclose " .. i)
    end
    
    log("Tab synchronization completed", vim.log.levels.INFO)
end

return M 