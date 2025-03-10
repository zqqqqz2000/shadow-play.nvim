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

    vim.notify(log_msg, level)

    if not config.log_file then return end
    local file = io.open(config.log_file, "a")
    if not file then return end

    file:write(log_msg .. "\n")
    file:close()
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
    if name == "" then return nil end

    local tab_info = {
        path = name,
        active = vim.api.nvim_get_current_win() == win,
        viewState = get_window_view_state(win)
    }

    log(string.format("Found buffer: %s (active: %s)", name, tostring(tab_info.active)), vim.log.levels.DEBUG)
    return tab_info
end

---Get all tabs information
---@return TabInfo[][]
local function get_tabs_info()
    log("Getting current tab information...", vim.log.levels.DEBUG)
    local tabs = {}

    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        local buffers = {}
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
            local info = get_window_info(win)
            if info then
                table.insert(buffers, info)
            end
        end

        if #buffers > 0 then
            table.insert(tabs, buffers)
        end
    end

    log(string.format("Found %d tabs with buffers", #tabs), vim.log.levels.DEBUG)
    return tabs
end

---Send message to VSCode/Cursor
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
        if callback then callback() end
    end)
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
            log(string.format("Updating view state for buffer: %s", data.path), vim.log.levels.DEBUG)
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
    local win = wins[j]
    if not win then
        log(string.format("Creating new window for buffer: %s", buf_info.path), vim.log.levels.DEBUG)
        vim.cmd("vsplit")
        win = vim.api.nvim_get_current_win()
    end

    log(string.format("Setting buffer %s in window", buf_info.path), vim.log.levels.DEBUG)
    vim.api.nvim_win_set_buf(win, vim.fn.bufnr(buf_info.path, true))

    if buf_info.active then
        log(string.format("Activating window for buffer: %s", buf_info.path), vim.log.levels.DEBUG)
        vim.api.nvim_set_current_win(win)
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

function M.sync_tabs()
    if not server then return end
    log("Starting tab synchronization", vim.log.levels.INFO)

    send_message({
        type = "tabs",
        data = get_tabs_info()
    })
end

function M.sync_buffer()
    if not server then return end

    local current_buf = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(current_buf)
    log(string.format("Buffer changed: %s", path), vim.log.levels.INFO)

    send_message({
        type = "buffer_change",
        data = { path = path }
    })
end

---Handle message from VSCode
---@param msg Message
local function handle_message(msg)
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
    log(string.format("Using socket path: %s", config.socket_path), vim.log.levels.INFO)

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

            if not chunk then
                log("Client disconnected", vim.log.levels.DEBUG)
                client:close()
                return
            end

            log(string.format("Received data: %s", chunk), vim.log.levels.DEBUG)
            local success, msg = pcall(vim.json.decode, chunk)

            if not success or type(msg) ~= "table" then
                log("Failed to parse received message", vim.log.levels.WARN)
                return
            end

            log(string.format("Processing message of type: %s", msg.type), vim.log.levels.DEBUG)
            vim.schedule(function()
                handle_message(msg)
            end)
        end)
    end)
end

return M
