---@type table<string, any>
local M = {}

---@type userdata
local uv = vim.uv or vim.loop -- Compatible with both Neovim 0.9 and 0.10+

---@type userdata|nil
local server

---@type userdata|nil
local client

---@type Config
local config

---@type string
local message_buffer = ''  -- 添加消息缓冲区

---Get detailed window info for logging
---@param win number Window handle
---@return string
local function get_window_details(win)
    local buf = vim.api.nvim_win_get_buf(win)
    local buf_name = vim.api.nvim_buf_get_name(buf)

    local tab = vim.api.nvim_win_get_tabpage(win)
    local tab_nr = vim.api.nvim_tabpage_get_number(tab)
    local win_nr = vim.api.nvim_win_get_number(win)
    return string.format("tab:%d win:%d buf:%s", tab_nr, win_nr, buf_name)
end

---@param msg string
---@param level number
---@param win? number Optional window handle for context
local function log(msg, level, win)
    if not config or not config.debug then return end

    level = level or vim.log.levels.INFO
    local level_str = ({
        [vim.log.levels.DEBUG] = "DEBUG",
        [vim.log.levels.INFO] = "INFO",
        [vim.log.levels.WARN] = "WARN",
        [vim.log.levels.ERROR] = "ERROR"
    })[level] or "INFO"

    local context = ""
    if win then
        context = "[" .. get_window_details(win) .. "] "
    end

    local log_msg = string.format("[%s][%s] %s%s",
        os.date("%Y-%m-%d %H:%M:%S"),
        level_str,
        context,
        msg
    )

    vim.notify(log_msg, level)

    if not config.log_file then return end
    local file = io.open(config.log_file, "a")
    if not file then return end

    file:write(log_msg .. "\n")
    file:close()
end

---Check if buffer should be ignored
---@param buf number Buffer handle
---@return boolean
local function should_ignore_buffer(buf)
    if buf == nil or buf == -1 then return true end
    local name = vim.api.nvim_buf_get_name(buf)
    local buftype = vim.bo[buf].buftype

    return name == "" or
        buftype == "nofile" or
        buftype == "terminal" or
        buftype == "help" or
        buftype == "quickfix" or
        buftype == "prompt"
end

---Get view state for a window
---@param win number Window handle
---@return ViewState
local function get_window_view_state(win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)

    return {
        cursor = {
            line = cursor[1] - 1,
            character = cursor[2]
        },
        scroll = {
            topLine = view.topline - 1,
            bottomLine = view.topline + vim.api.nvim_win_get_height(win) - 1
        }
    }
end
---Get tab info for a single window
---@param win number Window handle
---@return TabInfo|nil
local function get_window_info(win)
    local buf = vim.api.nvim_win_get_buf(win)
    local name = vim.api.nvim_buf_get_name(buf)
    local tab_info = {
        path = name,
        active = vim.api.nvim_get_current_win() == win,
        viewState = get_window_view_state(win)
    }

    return tab_info
end

---Filter out empty tabs and special buffers
---@param tabs TabInfo[][] Raw tabs information
---@return TabInfo[][]
local function filter_tabs(tabs)
    local filtered = {}
    for _, tab_info in ipairs(tabs) do
        local buffers = {}
        for _, buf_info in ipairs(tab_info) do
            if buf_info.path ~= "" then
                local bufnr = vim.fn.bufnr(buf_info.path)
                if bufnr > 0 and not should_ignore_buffer(bufnr) then
                    table.insert(buffers, buf_info)
                end
            end
        end
        if #buffers > 0 then
            table.insert(filtered, buffers)
        end
    end
    return filtered
end

---Get all tabs information
---@return TabInfo[][]
local function get_tabs_info()
    log("Getting current tab information...", vim.log.levels.DEBUG)
    local tabs = {}
    local buffer_order = {}  -- 用于记录缓冲区顺序

    -- 首先获取当前标签页结构
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        local buffers = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            local info = get_window_info(win)
            if info then
                local bufnr = vim.fn.bufnr(info.path)
                if bufnr > 0 then
                    buffer_order[bufnr] = #buffer_order + 1
                end
                table.insert(buffers, info)
            end
        end
        table.insert(tabs, buffers)
    end

    -- 获取所有打开的缓冲区
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if not should_ignore_buffer(buf) then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then
                -- 检查这个缓冲区是否已经在标签页中
                local found = false
                for _, tab_buffers in ipairs(tabs) do
                    for _, tab_buf in ipairs(tab_buffers) do
                        if tab_buf.path == name then
                            found = true
                            break
                        end
                    end
                    if found then break end
                end

                -- 如果缓冲区不在任何标签页中，创建一个新的标签页
                if not found then
                    if not buffer_order[buf] then
                        buffer_order[buf] = #buffer_order + 1
                    end
                    local info = {
                        path = name,
                        active = false,
                        viewState = {
                            cursor = { line = 0, character = 0 },
                            scroll = { topLine = 0, bottomLine = 0 }
                        }
                    }
                    table.insert(tabs, { info })
                end
            end
        end
    end

    -- 根据缓冲区顺序对标签页进行排序
    table.sort(tabs, function(a, b)
        local a_bufnr = vim.fn.bufnr(a[1].path)
        local b_bufnr = vim.fn.bufnr(b[1].path)
        return (buffer_order[a_bufnr] or 999999) < (buffer_order[b_bufnr] or 999999)
    end)

    log(string.format("Found %d tabs (including %d standalone buffers)", #tabs, #tabs - #vim.api.nvim_list_tabpages()), vim.log.levels.DEBUG)
    return tabs
end

---Send message to VSCode/Cursor
---@param msg Message
---@param callback? function Called when message is sent
local function send_message(msg, callback)
    if not client then
        log("No client connected, cannot send message", vim.log.levels.WARN)
        return
    end

    log(string.format("Sending message of type '%s'", msg.type), vim.log.levels.DEBUG)
    local json = vim.json.encode(msg)
    log(string.format("Sending data: %s", json), vim.log.levels.DEBUG)
    
    -- 添加 \0 作为结束符
    client:write(json .. "\0")
    log("Message sent successfully", vim.log.levels.DEBUG)
    if callback then callback() end
end

---Handle buffer change from VSCode
---@param path string File path
local function handle_buffer_change(path)
    log(string.format("Reloading buffer: %s", path), vim.log.levels.DEBUG)
    local bufnr = vim.fn.bufnr(path)

    if bufnr > 0 then
        log(string.format("Buffer found (bufnr: %d), reloading...", bufnr), vim.log.levels.DEBUG)
        vim.cmd(string.format("checktime %d", bufnr))
        return
    end

    log(string.format("Buffer not found for path: %s, opening it...", path), vim.log.levels.WARN)
    vim.schedule(function()
        vim.cmd(string.format("edit %s", vim.fn.fnameescape(path)))
        vim.cmd("checktime")
    end)
end

---Update window view state
---@param win number Window handle
---@param viewState ViewState View state to apply
local function update_window_view(win, viewState)
    -- Update cursor position (convert to 1-based)
    vim.api.nvim_win_set_cursor(win, {
        viewState.cursor.line + 1,
        viewState.cursor.character
    })

    -- Update scroll position
    vim.api.nvim_win_call(win, function()
        vim.fn.winrestview({
            topline = viewState.scroll.topLine + 1,
            leftcol = 0
        })
    end)
end

---Handle view change from VSCode
---@param data { path: string, viewState: ViewState }
local function handle_view_change(data)
    if not data.viewState then return end

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local name = vim.api.nvim_buf_get_name(buf)

        if name == data.path then
            log(string.format("Updating view state for buffer: %s", data.path), vim.log.levels.DEBUG, win)
            update_window_view(win, data.viewState)
            break
        end
    end
end

---Create or update a window in a tab
---@param tab number Tab handle
---@param wins number[] Window handles
---@param j number Window index
---@param buf_info TabInfo Buffer information
local function create_or_update_window(tab, wins, j, buf_info)
    -- Save current tab
    local current_tab = vim.api.nvim_get_current_tabpage()
    local win = wins[j]
    
    if not win then
        log(string.format("Creating new window for buffer: %s", vim.inspect(buf_info)), vim.log.levels.DEBUG)
        vim.api.nvim_set_current_tabpage(tab)
        vim.cmd("vsplit")
        win = vim.api.nvim_get_current_win()
    end

    vim.api.nvim_win_set_buf(win, vim.fn.bufnr(buf_info.path, true))

    if buf_info.active then
        log(string.format("Activating window for buffer: %s", vim.inspect(buf_info)), vim.log.levels.DEBUG)
        vim.api.nvim_set_current_tabpage(tab)
        vim.api.nvim_set_current_win(win)
    else
        -- If window is not active, restore original tab
        vim.api.nvim_set_current_tabpage(current_tab)
    end

    return win
end

---Handle tab synchronization from VSCode/Cursor
---@param tabs TabInfo[][]
local function handle_tab_sync(tabs)
    log(string.format("Starting tab sync with %d tabs", #tabs), vim.log.levels.INFO)
    local current_tabs = vim.api.nvim_list_tabpages()

    for i, tab_info in ipairs(tabs) do
        local tab = current_tabs[i]
        if not tab then
            log(string.format("Creating new tab %d", i), vim.log.levels.DEBUG)
            vim.cmd("tabnew")
            tab = vim.api.nvim_get_current_tabpage()
        end

        local wins = vim.api.nvim_tabpage_list_wins(tab)
        for j, buf_info in ipairs(tab_info) do
            create_or_update_window(tab, wins, j, buf_info)
        end

        -- Close extra windows
        for j = #tab_info + 1, #wins do
            local win = wins[j]
            local buf = vim.api.nvim_win_get_buf(win)
            if not should_ignore_buffer(buf) then
                local buf_name = vim.api.nvim_buf_get_name(buf)
                log(string.format("[tab:%d win:%d buf:%s] Closing extra window %d in tab %d", i, j, buf_name, j, i), vim.log.levels.DEBUG)
                vim.api.nvim_win_close(win, true)
            end
        end
    end

    -- Close extra tabs
    for i = #tabs + 1, #current_tabs do
        log(string.format("Closing extra tab %d", i), vim.log.levels.DEBUG)
        vim.cmd("tabclose " .. i)
    end

    log("Tab synchronization completed", vim.log.levels.INFO)
end

function M.sync_tabs()
    if not server then return end
    log("Starting tab synchronization", vim.log.levels.INFO)

    local tabs = get_tabs_info()
    local filtered_tabs = filter_tabs(tabs)
    log(string.format("Filtered to %d valid tabs", #filtered_tabs), vim.log.levels.DEBUG)

    send_message({
        type = "tabs",
        data = filtered_tabs
    })
end

function M.sync_buffer()
    if not server then return end

    local current_buf = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(current_buf)
    log(string.format("Buffer changed: %s", path), vim.log.levels.INFO)

    send_message({
        type = "buffer_change",
        data = { path = path },
        from_nvim = true
    })
end

---Handle message from VSCode
---@param msg Message
local function handle_message(msg)
    -- 忽略来自插件的消息
    if msg.from_nvim then
        log("Ignoring message from plugin", vim.log.levels.DEBUG)
        return
    end

    if msg.type == "tabs" then
        log("Handling tab sync from VSCode", vim.log.levels.INFO)
        handle_tab_sync(msg.data)
    elseif msg.type == "buffer_change" then
        log("Handling buffer change from VSCode", vim.log.levels.INFO)
        handle_buffer_change(msg.data.path)
    elseif msg.type == "view_change" then
        log("Handling view change from VSCode", vim.log.levels.INFO)
        handle_view_change(msg.data)
    end
end

---Initialize sync service
---@param user_config Config
function M.init(user_config)
    config = user_config
    log("Initializing Shadow Play sync service", vim.log.levels.INFO)

    server = uv.new_pipe()
    -- Ensure using project root directory for socket path
    local socket_path = config.socket_path or (vim.fn.getcwd() .. "/shadow-play.sock")
    log(string.format("Using socket path: %s", socket_path), vim.log.levels.INFO)

    if vim.fn.filereadable(socket_path) == 1 then
        log("Removing existing socket file", vim.log.levels.DEBUG)
        vim.fn.delete(socket_path)
    end

    local ok, err = server:bind(socket_path)
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
        
        -- Handle new client connection
        local function handle_new_client()
            -- Close existing connection if any
            if client then
                client:close()
                client = nil
            end
            
            client = uv.new_pipe()
            server:accept(client)
            log("New client connection accepted", vim.log.levels.DEBUG)

            client:read_start(function(err, chunk)
                if err then
                    log(string.format("Failed to read data: %s", err), vim.log.levels.ERROR)
                    client:close()
                    client = nil
                    -- Prepare to accept new connection
                    vim.schedule(handle_new_client)
                    return
                end

                if not chunk then
                    log("Client disconnected", vim.log.levels.DEBUG)
                    client:close()
                    client = nil
                    -- Prepare to accept new connection
                    vim.schedule(handle_new_client)
                    return
                end

                -- 将新数据添加到缓冲区
                message_buffer = message_buffer .. chunk
                
                -- 处理所有完整的消息
                while true do
                    local null_index = message_buffer:find('\0')
                    if not null_index then
                        -- 没有找到结束符，等待更多数据
                        break
                    end
                    
                    -- 提取一个完整的消息
                    local message_str = message_buffer:sub(1, null_index - 1)
                    -- 更新缓冲区，移除已处理的消息
                    message_buffer = message_buffer:sub(null_index + 1)
                    
                    if message_str == '' then
                        goto continue
                    end
                    
                    local ok, message = pcall(vim.json.decode, message_str)
                    if ok then
                        log('Received message: ' .. message_str, vim.log.levels.DEBUG)
                        handle_message(message)
                    else
                        log('Failed to parse message: ' .. message, vim.log.levels.ERROR)
                    end
                    
                    ::continue::
                end
            end)
        end

        -- Start accepting connections
        handle_new_client()
    end)
end

return M
