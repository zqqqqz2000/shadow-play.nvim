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
local message_buffer = ''  -- Add message buffer

--- Add lock variable
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

---Default buffer distribution algorithm
---@param buffers string[] List of all buffer paths
---@param num_windows number Number of windows
---@return string[][] Distributed buffer list, each sublist corresponds to a window
local function default_buffer_distribution(buffers, num_windows)
    local result = {}
    for i = 1, num_windows do
        result[i] = {}
    end

    -- If there's only one window, assign all buffers to it
    if num_windows == 1 then
        result[1] = buffers
        return result
    end

    -- Otherwise, distribute evenly
    local current_window = 1
    for _, buf in ipairs(buffers) do
        table.insert(result[current_window], buf)
        current_window = current_window % num_windows + 1
    end

    return result
end

---Get window split type
---@param win number Window ID
---@return string "leaf"|"vsplit"|"hsplit"
local function get_window_split_type(win)
    if not vim.api.nvim_win_is_valid(win) then
        return "leaf"
    end
    
    -- Get adjacent windows
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local win_info = vim.fn.getwininfo(win)[1]
    
    -- Check for adjacent windows
    for _, w in ipairs(wins) do
        if w ~= win then
            local info = vim.fn.getwininfo(w)[1]
            -- If windows are in the same row but different columns, it's a vertical split
            if info.winrow == win_info.winrow then
                return "vsplit"
            end
            -- If windows are in the same column but different rows, it's a horizontal split
            if info.wincol == win_info.wincol then
                return "hsplit"
            end
        end
    end
    
    return "leaf"
end

---Get child windows
---@param win number Window ID
---@return number[] List of child window IDs
local function get_window_children(win)
    local children = {}
    local wins = vim.api.nvim_tabpage_list_wins(0)
    local win_info = vim.fn.getwininfo(win)[1]
    
    for _, w in ipairs(wins) do
        if w ~= win then
            local info = vim.fn.getwininfo(w)[1]
            -- Check if it's an adjacent window
            if info.winrow == win_info.winrow or info.wincol == win_info.wincol then
                table.insert(children, w)
            end
        end
    end
    
    return children
end

---Get current tab page window information
---@return WindowLayout
local function get_windows_info()
    log("Getting current windows information...", vim.log.levels.DEBUG)
    local current_tab = vim.api.nvim_get_current_tabpage()
    local wins = vim.api.nvim_tabpage_list_wins(current_tab)
    local active_windows = {}
    local all_buffers = {}
    local buffer_order = {}

    -- Collect all valid windows
    for _, win in ipairs(wins) do
        local buf = vim.api.nvim_win_get_buf(win)
        if not should_ignore_buffer(buf) then
            table.insert(active_windows, win)
        end
    end

    -- Collect all open buffers
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if not should_ignore_buffer(buf) then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then
                table.insert(all_buffers, name)
                buffer_order[name] = #buffer_order + 1
            end
        end
    end

    -- Use buffer distribution algorithm
    local distribution_func = buffer_distribution_algorithm or default_buffer_distribution
    local distributed_buffers = distribution_func(all_buffers, #active_windows)

    -- If there's only one window, return a leaf node
    if #active_windows == 1 then
        local win = active_windows[1]
        local window_buffers = {}
        for _, buf_path in ipairs(distributed_buffers[1] or {}) do
            local info = {
                path = buf_path,
                active = vim.api.nvim_win_get_buf(win) == vim.fn.bufnr(buf_path),
                viewState = get_window_view_state(win)
            }
            table.insert(window_buffers, info)
        end
        return {
            type = "leaf",
            buffers = window_buffers
        }
    end

    -- For multiple windows, determine split type based on first window
    local split_type = get_window_split_type(active_windows[1])
    local children = {}
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
            table.insert(children, {
                type = "leaf",
                buffers = window_buffers,
                size = 1 / #active_windows  -- Equal space distribution
            })
        end
    end

    log(string.format("Found %d windows with %d total buffers", #children, #all_buffers), vim.log.levels.DEBUG)
    return {
        type = split_type,
        children = children
    }
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
    
    -- Add \0 as message terminator
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

---Report sync error
---@param msg string Error message
local function report_sync_error(msg)
    log(msg, vim.log.levels.ERROR)
    vim.notify("Shadow Play: " .. msg, vim.log.levels.ERROR)
end

---Recursively synchronize window layout
---@param layout WindowLayout Target layout configuration
---@param win? number Current window ID
---@return number Returns synchronized window ID
local function sync_window_layout(layout, win)
    -- If no window provided, sync all windows from current tab
    if not win then
        local current_tab = vim.api.nvim_get_current_tabpage()
        local wins = vim.api.nvim_tabpage_list_wins(current_tab)
        local valid_wins = {}
        
        -- Collect all valid windows
        for _, w in ipairs(wins) do
            local buf = vim.api.nvim_win_get_buf(w)
            if not should_ignore_buffer(buf) then
                table.insert(valid_wins, w)
            end
        end

        -- If no valid windows, create a new one
        if #valid_wins == 0 then
            vim.cmd('new')
            win = vim.api.nvim_get_current_win()
            return sync_window_layout(layout, win)
        end

        -- Special handling for auto type layout
        if layout.type == "auto" then
            -- Compare window counts
            local layout_window_count = #layout.children
            if layout_window_count ~= #valid_wins then
                -- Report error and stop sync
                report_sync_error(string.format(
                    "Window count mismatch: Vim has %d windows but VSCode has %d windows. Sync aborted.",
                    #valid_wins,
                    layout_window_count
                ))
                return valid_wins[1]
            end

            -- Window counts match, sync content to each window
            for i, win in ipairs(valid_wins) do
                local child_layout = layout.children[i]
                if child_layout and child_layout.buffers then
                    -- 确保所有 buffer 都已加载
                    for _, buf_info in ipairs(child_layout.buffers) do
                        local bufnr = vim.fn.bufnr(buf_info.path)
                        if bufnr == -1 then
                            bufnr = vim.fn.bufadd(buf_info.path)
                            vim.bo[bufnr].buflisted = true
                        end
                    end

                    -- 设置激活的 buffer
                    local active_buffer = nil
                    for _, buf_info in ipairs(child_layout.buffers) do
                        if buf_info.active then
                            active_buffer = vim.fn.bufnr(buf_info.path)
                            -- 设置 buffer 并更新视图状态
                            vim.api.nvim_win_set_buf(win, active_buffer)
                            if buf_info.viewState then
                                update_window_view(win, buf_info.viewState)
                            end
                            break
                        end
                    end

                    -- 如果没有激活的 buffer，使用第一个
                    if not active_buffer and #child_layout.buffers > 0 then
                        local first_buf = child_layout.buffers[1]
                        active_buffer = vim.fn.bufnr(first_buf.path)
                        vim.api.nvim_win_set_buf(win, active_buffer)
                        if first_buf.viewState then
                            update_window_view(win, first_buf.viewState)
                        end
                    end
                end
            end
            return valid_wins[1]
        end

        -- Compare existing window layout with target layout
        if layout.type == "leaf" then
            -- If target is leaf but have multiple windows, close extra windows
            win = valid_wins[1]
            for i = 2, #valid_wins do
                if vim.api.nvim_win_is_valid(valid_wins[i]) then
                    vim.api.nvim_win_close(valid_wins[i], true)
                end
            end
            return sync_window_layout(layout, win)
        else
            -- For split nodes, check if split type matches
            local current_split_type = get_window_split_type(valid_wins[1])
            
            -- If split type or window count doesn't match, recreate layout
            if current_split_type ~= layout.type or #valid_wins ~= #layout.children then
                -- Keep first window, close others
                win = valid_wins[1]
                for i = 2, #valid_wins do
                    if vim.api.nvim_win_is_valid(valid_wins[i]) then
                        vim.api.nvim_win_close(valid_wins[i], true)
                    end
                end
                return sync_window_layout(layout, win)
            else
                -- Split type and window count match, recursively sync each child window
                local wins = {}
                for i, child_layout in ipairs(layout.children) do
                    wins[i] = sync_window_layout(child_layout, valid_wins[i])
                end
                
                -- Set window sizes
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
                
                return wins[1]
            end
        end
    end

    -- Ensure window is valid
    if not vim.api.nvim_win_is_valid(win) then
        vim.cmd('new')
        win = vim.api.nvim_get_current_win()
    end

    log(string.format("Syncing window %d with layout type %s", win, layout.type), vim.log.levels.DEBUG)

    if layout.type == "leaf" then
        -- Handle leaf node
        local active_buffer
        -- Find active buffer
        for _, buf_info in ipairs(layout.buffers) do
            if buf_info.active then
                local bufnr = vim.fn.bufnr(buf_info.path)
                if bufnr == -1 then
                    bufnr = vim.fn.bufadd(buf_info.path)
                    vim.bo[bufnr].buflisted = true
                end
                active_buffer = bufnr
                -- Set buffer
                vim.api.nvim_win_set_buf(win, bufnr)
                -- Restore view state
                if buf_info.viewState then
                    update_window_view(win, buf_info.viewState)
                end
                break
            end
        end
        return win
    else
        -- Create new splits
        local wins = {}
        local first_win = win
        
        for i, child_layout in ipairs(layout.children) do
            if i == 1 then
                wins[i] = sync_window_layout(child_layout, first_win)
            else
                -- Create new window
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
        
        -- Set window sizes
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
    end
end

---Handle editor group synchronization from VSCode
---@param layout WindowLayout
local function handle_editor_group_sync(layout)
    log("Starting window layout synchronization", vim.log.levels.INFO)
    -- Sync window layout
    sync_window_layout(layout)
    log("Window layout synchronization completed", vim.log.levels.INFO)
end

---Handle message from VSCode
---@param msg Message
local function handle_message(msg)
    -- Ignore messages from plugin
    if msg.from_nvim then
        log("Ignoring message from plugin", vim.log.levels.DEBUG)
        return
    end

    -- Set lock
    is_handling_message = true
    log("Message handling started, lock acquired", vim.log.levels.DEBUG)

    -- Use pcall to ensure lock is released even if error occurs
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

    -- Release lock
    is_handling_message = false
    log("Message handling completed, lock released", vim.log.levels.DEBUG)

    -- If error occurred during processing, log it
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

                -- Add new data to buffer
                message_buffer = message_buffer .. chunk
                
                -- Process all complete messages
                while true do
                    local null_index = message_buffer:find('\0')
                    if not null_index then
                        -- No end character found, wait for more data
                        break
                    end
                    
                    -- Extract a complete message
                    local message_str = message_buffer:sub(1, null_index - 1)
                    -- Update buffer, remove processed message
                    message_buffer = message_buffer:sub(null_index + 1)
                    
                    if message_str == '' then
                        goto continue
                    end
                    
                    local ok, message = pcall(vim.json.decode, message_str)
                    if ok then
                        log('Received message: ' .. message_str, vim.log.levels.DEBUG)
                        -- Use vim.schedule to handle message
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

---Set custom buffer distribution algorithm
---@param func function Custom distribution algorithm function
function M.set_buffer_distribution_algorithm(func)
    buffer_distribution_algorithm = func
end

function M.sync_wins()
    if not server then return end
    -- Skip sync if handling message
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

