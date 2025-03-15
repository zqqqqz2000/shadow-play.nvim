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

--- 添加锁变量
local is_handling_message = false

---@type function|nil
local buffer_distribution_algorithm = nil

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
    local is_loaded = vim.api.nvim_buf_is_loaded(buf)
    local is_listed = vim.fn.buflisted(buf) == 1

    return name == "" or
        not is_loaded or
        not is_listed or
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

---Get window info for a single window
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

---默认的缓冲区分配算法
---@param buffers string[] 所有缓冲区路径列表
---@param num_windows number 窗口数量
---@return string[][] 分配后的缓冲区列表，每个子列表对应一个窗口
local function default_buffer_distribution(buffers, num_windows)
    local result = {}
    for i = 1, num_windows do
        result[i] = {}
    end

    -- 如果窗口数量为1，所有缓冲区都分配给这个窗口
    if num_windows == 1 then
        result[1] = buffers
        return result
    end

    -- 否则，尽量平均分配
    local current_window = 1
    for _, buf in ipairs(buffers) do
        table.insert(result[current_window], buf)
        current_window = current_window % num_windows + 1
    end

    return result
end

---获取当前标签页的所有窗口信息
---@return TabInfo[][]
local function get_windows_info()
    log("Getting current windows information...", vim.log.levels.DEBUG)
    local current_tab = vim.api.nvim_get_current_tabpage()
    local wins = vim.api.nvim_tabpage_list_wins(current_tab)
    local active_windows = {}
    local all_buffers = {}
    local buffer_order = {}

    -- 收集所有可用的窗口
    for _, win in ipairs(wins) do
        local buf = vim.api.nvim_win_get_buf(win)
        if not should_ignore_buffer(buf) then
            table.insert(active_windows, win)
        end
    end

    -- 收集所有打开的缓冲区
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if not should_ignore_buffer(buf) then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then
                table.insert(all_buffers, name)
                buffer_order[name] = #buffer_order + 1
            end
        end
    end

    -- 使用缓冲区分配算法
    local distribution_func = buffer_distribution_algorithm or default_buffer_distribution
    local distributed_buffers = distribution_func(all_buffers, #active_windows)

    -- 构建最终的窗口信息
    local windows_info = {}
    for i, win in ipairs(active_windows) do
        local window_buffers = {}
        for _, buf_path in ipairs(distributed_buffers[i] or {}) do
            local info = {
                path = buf_path,
                active = vim.api.nvim_win_get_buf(win) == vim.fn.bufnr(buf_path),
                viewState = get_window_view_state(win)
            }
            table.insert(window_buffers, info)
        end
        if #window_buffers > 0 then
            table.insert(windows_info, window_buffers)
        end
    end

    log(string.format("Found %d windows with %d total buffers", #windows_info, #all_buffers), vim.log.levels.DEBUG)
    return windows_info
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

---获取窗口的分割类型
---@param win number 窗口ID
---@return string "leaf"|"vsplit"|"hsplit"
local function get_window_split_type(win)
    if not vim.api.nvim_win_is_valid(win) then
        return "leaf"
    end
    
    -- 获取相邻窗口
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local win_info = vim.fn.getwininfo(win)[1]
    
    -- 检查是否有相邻窗口
    for _, w in ipairs(wins) do
        if w ~= win then
            local info = vim.fn.getwininfo(w)[1]
            -- 如果窗口在同一行但列不同，是垂直分割
            if info.winrow == win_info.winrow then
                return "vsplit"
            end
            -- 如果窗口在同一列但行不同，是水平分割
            if info.wincol == win_info.wincol then
                return "hsplit"
            end
        end
    end
    
    return "leaf"
end

---获取窗口的子窗口
---@param win number 窗口ID
---@return number[] 子窗口ID列表
local function get_window_children(win)
    local children = {}
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local win_info = vim.fn.getwininfo(win)[1]
    
    for _, w in ipairs(wins) do
        if w ~= win then
            local info = vim.fn.getwininfo(w)[1]
            -- 检查是否是相邻窗口
            if info.winrow == win_info.winrow or info.wincol == win_info.wincol then
                table.insert(children, w)
            end
        end
    end
    
    return children
end

---递归同步窗口布局
---@param layout WindowLayout 目标布局配置
---@param win? number 当前窗口ID
---@return number 返回同步后的窗口ID
local function sync_window_layout(layout, win)
    -- 如果没有提供窗口，使用当前窗口
    if not win then
        win = vim.api.nvim_get_current_win()
    end

    -- 确保窗口有效
    if not vim.api.nvim_win_is_valid(win) then
        vim.cmd('new')
        win = vim.api.nvim_get_current_win()
    end

    log(string.format("Syncing window %d with layout type %s", win, layout.type), vim.log.levels.DEBUG)

    if layout.type == "leaf" then
        -- 处理叶子节点
        local active_buffer
        -- 找到活动缓冲区
        for _, buf_info in ipairs(layout.buffers) do
            if buf_info.active then
                local bufnr = vim.fn.bufnr(buf_info.path)
                if bufnr == -1 then
                    bufnr = vim.fn.bufadd(buf_info.path)
                    vim.bo[bufnr].buflisted = true
                end
                active_buffer = bufnr
                -- 设置缓冲区
                vim.api.nvim_win_set_buf(win, bufnr)
                -- 恢复视图状态
                if buf_info.viewState then
                    update_window_view(win, buf_info.viewState)
                end
                break
            end
        end
        return win
    else
        local current_type = get_window_split_type(win)
        local children = get_window_children(win)
        
        -- 如果分割类型不同，需要重新创建
        if current_type ~= layout.type then
            log(string.format("Split type mismatch: current=%s, target=%s", current_type, layout.type), vim.log.levels.DEBUG)
            -- 关闭所有子窗口
            for _, child in ipairs(children) do
                if vim.api.nvim_win_is_valid(child) then
                    vim.api.nvim_win_close(child, true)
                end
            end
            
            -- 创建新的分割
            local wins = {}
            local first_win = win
            
            for i, child_layout in ipairs(layout.children) do
                if i == 1 then
                    wins[i] = sync_window_layout(child_layout, first_win)
                else
                    -- 创建新窗口
                    vim.api.nvim_set_current_win(first_win)
                    if layout.type == "vsplit" then
                        vim.cmd('vsplit')
                    else
                        vim.cmd('split')
                    end
                    local new_win = vim.api.nvim_get_current_win()
                    wins[i] = sync_window_layout(child_layout, new_win)
                end
            end
            
            -- 设置窗口大小
            if #wins > 1 then
                local total_size = (layout.type == "vsplit") and vim.o.columns or vim.o.lines
                for i, w in ipairs(wins) do
                    if i < #wins and layout.children[i].size and vim.api.nvim_win_is_valid(w) then
                        local size = math.floor(total_size * layout.children[i].size)
                        if layout.type == "vsplit" then
                            vim.api.nvim_win_set_width(w, size)
                        else
                            vim.api.nvim_win_set_height(w, size)
                        end
                    end
                end
            end
            
            return first_win
        else
            -- 分割类型相同，递归同步子窗口
            local wins = {}
            for i, child_layout in ipairs(layout.children) do
                if i <= #children and vim.api.nvim_win_is_valid(children[i]) then
                    -- 复用现有窗口
                    wins[i] = sync_window_layout(child_layout, children[i])
                else
                    -- 创建新窗口
                    vim.api.nvim_set_current_win(win)
                    if layout.type == "vsplit" then
                        vim.cmd('vsplit')
                    else
                        vim.cmd('split')
                    end
                    local new_win = vim.api.nvim_get_current_win()
                    wins[i] = sync_window_layout(child_layout, new_win)
                end
            end
            
            -- 关闭多余的窗口
            for i = #layout.children + 1, #children do
                if vim.api.nvim_win_is_valid(children[i]) then
                    vim.api.nvim_win_close(children[i], true)
                end
            end
            
            -- 设置窗口大小
            if #wins > 1 then
                local total_size = (layout.type == "vsplit") and vim.o.columns or vim.o.lines
                for i, w in ipairs(wins) do
                    if i < #wins and layout.children[i].size and vim.api.nvim_win_is_valid(w) then
                        local size = math.floor(total_size * layout.children[i].size)
                        if layout.type == "vsplit" then
                            vim.api.nvim_win_set_width(w, size)
                        else
                            vim.api.nvim_win_set_height(w, size)
                        end
                    end
                end
            end
            
            return win
        end
    end
end

---Handle editor group synchronization from VSCode
---@param layout WindowLayout
local function handle_editor_group_sync(layout)
    log("Starting window layout synchronization", vim.log.levels.INFO)

    -- 保存当前窗口
    local current_win = vim.api.nvim_get_current_win()

    -- 同步窗口布局
    sync_window_layout(layout)

    -- 恢复当前窗口（如果还有效）
    if vim.api.nvim_win_is_valid(current_win) then
        vim.api.nvim_set_current_win(current_win)
    end

    log("Window layout synchronization completed", vim.log.levels.INFO)
end

---Handle message from VSCode
---@param msg Message
local function handle_message(msg)
    -- 忽略来自插件的消息
    if msg.from_nvim then
        log("Ignoring message from plugin", vim.log.levels.DEBUG)
        return
    end

    -- 设置锁
    is_handling_message = true
    log("Message handling started, lock acquired", vim.log.levels.DEBUG)

    -- 使用 pcall 确保即使出错也能解锁
    local ok, err = pcall(function()
        if msg.type == "editor_group" then
            log("Handling tab sync from VSCode", vim.log.levels.INFO)
            handle_editor_group_sync(msg.data)
        elseif msg.type == "buffer_change" then
            log("Handling buffer change from VSCode", vim.log.levels.INFO)
            handle_buffer_change(msg.data.path)
        elseif msg.type == "view_change" then
            log("Handling view change from VSCode", vim.log.levels.INFO)
            handle_view_change(msg.data)
        end
    end)

    -- 解锁
    is_handling_message = false
    log("Message handling completed, lock released", vim.log.levels.DEBUG)

    -- 如果处理过程中出错，记录错误
    if not ok then
        log("Error while handling message: " .. tostring(err), vim.log.levels.ERROR)
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
                        -- 使用 vim.schedule 来处理消息
                        vim.schedule(function()
                            handle_message(message)
                        end)
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

---设置自定义的缓冲区分配算法
---@param func function 自定义的分配算法函数
function M.set_buffer_distribution_algorithm(func)
    buffer_distribution_algorithm = func
end

function M.sync_wins()
    if not server then return end
    -- 如果正在处理消息，不触发同步
    if is_handling_message then
        log("Skipping window sync while handling message", vim.log.levels.DEBUG)
        return
    end

    log("Starting window synchronization", vim.log.levels.INFO)

    local windows_info = get_windows_info()
    send_message({
        type = "editor_group",
        data = windows_info,
        from_nvim = true
    })
end

return M

