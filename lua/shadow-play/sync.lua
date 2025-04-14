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
local message_buffer = "" -- Add message buffer

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
	if not config or not config.debug then
		return
	end

	level = level or vim.log.levels.INFO
	local level_str = ({
		[vim.log.levels.DEBUG] = "DEBUG",
		[vim.log.levels.INFO] = "INFO",
		[vim.log.levels.WARN] = "WARN",
		[vim.log.levels.ERROR] = "ERROR",
	})[level] or "INFO"

	local context = ""
	if win then
		context = "[" .. get_window_details(win) .. "] "
	end

	local log_msg = string.format("[%s][%s] %s%s", os.date("%Y-%m-%d %H:%M:%S"), level_str, context, msg)

	if not config.log_file then
		return
	end
	local file = io.open(config.log_file, "a")
	if not file then
		return
	end

	file:write(log_msg .. "\n")
	file:close()
end

---Check if buffer should be ignored
---@param buf number Buffer handle
---@return boolean
local function should_ignore_buffer(buf)
	if buf == nil or buf == -1 then
		return true
	end
	local name = vim.api.nvim_buf_get_name(buf)
	local buftype = vim.bo[buf].buftype
	local is_loaded = vim.api.nvim_buf_is_loaded(buf)
	local is_listed = vim.fn.buflisted(buf) == 1
	log(
		string.format(
			"Checking buffer %d: name=%s, buftype=%s, is_loaded=%s, is_listed=%s",
			buf,
			name,
			buftype,
			is_loaded,
			is_listed
		),
		vim.log.levels.DEBUG
	)

	return name == ""
		or not is_loaded
		or not is_listed
		or buftype == "nofile"
		or buftype == "terminal"
		or buftype == "help"
		or buftype == "quickfix"
		or buftype == "prompt"
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
			character = cursor[2],
		},
		scroll = {
			topLine = view.topline - 1,
			bottomLine = view.topline + vim.api.nvim_win_get_height(win) - 1,
		},
	}
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

---Build window tree recursively from a given window
---@param current_win number Currently focused window
---@param all_buffers string[] List of all buffer paths
---@return WindowLayout
local function build_window_tree(current_win, all_buffers)
	-- 首先获取所有的窗口
	local tab = vim.api.nvim_win_get_tabpage(current_win)
	local all_wins = vim.api.nvim_tabpage_list_wins(tab)
	local valid_wins = {}
	local windows_info = {}
	local current_win_info = {}
	
	-- 收集所有有效窗口的信息
	for _, win in ipairs(all_wins) do
		local buf = vim.api.nvim_win_get_buf(win)
		if not should_ignore_buffer(buf) then
			local win_info = vim.fn.getwininfo(win)[1]
			
			-- 记录窗口信息
			local info = {
				id = win,
				buf = buf,
				active = (win == current_win),
				wincol = win_info.wincol,
				winrow = win_info.winrow,
				width = win_info.width,
				height = win_info.height,
				processed = false
			}
			
			table.insert(valid_wins, win)
			table.insert(windows_info, info)
			
			if win == current_win then
				current_win_info = info
			end
		end
	end
	
	-- 如果只有一个窗口，直接返回叶子节点
	if #valid_wins == 1 then
		local win = valid_wins[1]
		local buf = vim.api.nvim_win_get_buf(win)
		local path = vim.api.nvim_buf_get_name(buf)
		local viewState = get_window_view_state(win)
		
		return {
			type = "leaf",
			buffers = {
				{
					path = path,
					active = true,
					viewState = viewState
				}
			},
			active = true
		}
	end
	
	-- 通用函数：根据位置关系将窗口分组
	---@param windows table[] 窗口信息列表
	---@param is_same_group function 判断两个窗口是否在同一组的函数
	---@return table[] 分组后的窗口列表
	local function group_windows(windows, is_same_group)
		local groups = {}
		local processed = {}
		
		for i, win in ipairs(windows) do
			if not processed[i] then
				local group = {win}
				processed[i] = true
				
				for j = i + 1, #windows do
					if not processed[j] and is_same_group(win, windows[j]) then
						table.insert(group, windows[j])
						processed[j] = true
					end
				end
				
				table.insert(groups, group)
			end
		end
		
		return groups
	end
	
	-- 分析窗口水平和垂直关系
	local function analyze_layout(windows)
		-- 如果只有一个窗口，返回叶子节点
		if #windows == 1 then
			local win = windows[1]
			win.processed = true
			
			local buf = vim.api.nvim_win_get_buf(win.id)
			local path = vim.api.nvim_buf_get_name(buf)
			local viewState = get_window_view_state(win.id)
			
			return {
				type = "leaf",
				buffers = {
					{
						path = path,
						active = win.active,
						viewState = viewState
					}
				},
				active = win.active
			}
		end
		
		-- 判断窗口是否在同一行
		local function same_row(win1, win2)
			return win1.winrow == win2.winrow
		end
		
		-- 判断窗口是否在同一列
		local function same_col(win1, win2)
			return win1.wincol == win2.wincol
		end
		
		-- 尝试垂直分割（同一行的窗口）
		local row_groups = group_windows(windows, same_row)
		if #row_groups > 1 then
			-- 垂直分割成功
			local children = {}
			local is_active = false
			
			-- 按列排序
			table.sort(row_groups, function(a, b)
				return a[1].wincol < b[1].wincol
			end)
			
			-- 为每个组创建子布局
			local total_width = 0
			for _, group in ipairs(row_groups) do
				total_width = total_width + group[1].width
			end
			
			for _, group in ipairs(row_groups) do
				local child = analyze_layout(group)
				child.size = group[1].width / total_width
				table.insert(children, child)
				if child.active then
					is_active = true
				end
			end
			
			return {
				type = "hsplit",
				children = children,
				active = is_active
			}
		end
		
		-- 尝试水平分割（同一列的窗口）
		local col_groups = group_windows(windows, same_col)
		if #col_groups > 1 then
			-- 水平分割成功
			local children = {}
			local is_active = false
			
			-- 按行排序
			table.sort(col_groups, function(a, b)
				return a[1].winrow < b[1].winrow
			end)
			
			-- 为每个组创建子布局
			local total_height = 0
			for _, group in ipairs(col_groups) do
				total_height = total_height + group[1].height
			end
			
			for _, group in ipairs(col_groups) do
				local child = analyze_layout(group)
				child.size = group[1].height / total_height
				table.insert(children, child)
				if child.active then
					is_active = true
				end
			end
			
			return {
				type = "vsplit",
				children = children,
				active = is_active
			}
		end
		
		-- 如果无法分割，则创建一个叶子节点（通常不会发生，但作为兜底）
		log("Unable to determine window layout, defaulting to leaf", vim.log.levels.WARN)
		local win = windows[1]
		win.processed = true
		
		local buf = vim.api.nvim_win_get_buf(win.id)
		local path = vim.api.nvim_buf_get_name(buf)
		local viewState = get_window_view_state(win.id)
		
		return {
			type = "leaf",
			buffers = {
				{
					path = path,
					active = win.active,
					viewState = viewState
				}
			},
			active = win.active
		}
	end
	
	-- 分析窗口布局并生成树结构
	local layout = analyze_layout(windows_info)
	
	-- 为叶子节点分配所有可用的缓冲区
	local function assign_buffers(node, buffers)
		if node.type == "leaf" then
			-- 如果当前只有一个buffer，并且是active的，需要将其他buffer也加入
			local active_path = node.buffers[1].path
			node.buffers = {}
			
			-- 将所有buffer添加到这个节点，确保原来的active buffer仍然是active
			for _, buf_path in ipairs(buffers) do
				table.insert(node.buffers, {
					path = buf_path,
					active = (buf_path == active_path),
					viewState = nil -- 非活动buffer没有视图状态
				})
			end
		else
			-- 递归处理子节点
			for _, child in ipairs(node.children) do
				assign_buffers(child, buffers)
			end
		end
	end
	
	-- 如果enable_buffer_distribution为true，则将所有可用buffer分配给叶子节点
	if buffer_distribution_algorithm then
		local leaf_count = 0
		local function count_leaves(node)
			if node.type == "leaf" then
				leaf_count = leaf_count + 1
			else
				for _, child in ipairs(node.children) do
					count_leaves(child)
				end
			end
		end
		count_leaves(layout)
		
		-- 将buffer分配给各个窗口
		local distributed_buffers = buffer_distribution_algorithm(all_buffers, leaf_count)
		
		-- 递归分配buffer
		local leaf_index = 1
		local function assign_distributed_buffers(node)
			if node.type == "leaf" then
				local active_path = node.buffers[1].path
				node.buffers = {}
				
				-- 将分配的buffer添加到这个节点
				for _, buf_path in ipairs(distributed_buffers[leaf_index] or {}) do
					table.insert(node.buffers, {
						path = buf_path,
						active = (buf_path == active_path),
						viewState = nil
					})
				end
				leaf_index = leaf_index + 1
			else
				for _, child in ipairs(node.children) do
					assign_distributed_buffers(child)
				end
			end
		end
		assign_distributed_buffers(layout)
	else
		-- 默认情况下，将所有buffer分配给每个叶子节点
		assign_buffers(layout, all_buffers)
	end
	
	return layout
end

---Get current tab page window information
---@return WindowLayout
local function get_windows_info()
	log("Getting current windows information...", vim.log.levels.DEBUG)
	local current_tab = vim.api.nvim_get_current_tabpage()
	local wins = vim.api.nvim_tabpage_list_wins(current_tab)
	local current_win = vim.api.nvim_get_current_win()
	log(string.format("Found %d total windows in current tab", #wins), vim.log.levels.DEBUG)

	local valid_wins = {}
	local all_buffers = {}

	-- Collect all valid windows
	for _, win in ipairs(wins) do
		local buf = vim.api.nvim_win_get_buf(win)
		local buf_name = vim.api.nvim_buf_get_name(buf)
		if not should_ignore_buffer(buf) then
			table.insert(valid_wins, win)
			log(string.format("Added valid window %d with buffer '%s'", win, buf_name), vim.log.levels.DEBUG)
		else
			log(string.format("Ignoring window %d with buffer '%s'", win, buf_name), vim.log.levels.DEBUG)
		end
	end
	log(string.format("Found %d valid windows after filtering", #valid_wins), vim.log.levels.DEBUG)

	-- Collect all open buffers
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(buf)
		if not should_ignore_buffer(buf) then
			if name ~= "" then
				table.insert(all_buffers, name)
				log(string.format("Added valid buffer '%s'", name), vim.log.levels.DEBUG)
			end
		else
			log(string.format("Ignoring buffer '%s'", name), vim.log.levels.DEBUG)
		end
	end
	log(string.format("Found %d valid buffers after filtering", #all_buffers), vim.log.levels.DEBUG)

	-- If there are no valid windows, return empty layout
	if #valid_wins == 0 then
		log("No valid windows found, returning empty layout", vim.log.levels.DEBUG)
		return {
			type = "leaf",
			buffers = {},
			active = true,
		}
	end
	
	-- Build window tree recursively starting from root window
	local window_tree = build_window_tree(current_win, all_buffers)
	return window_tree
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
	if callback then
		callback()
	end
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
		viewState.cursor.character,
	})

	-- Update scroll position
	vim.api.nvim_win_call(win, function()
		vim.fn.winrestview({
			topline = viewState.scroll.topLine + 1,
			leftcol = 0,
		})
	end)
end

---Handle view change from VSCode
---@param data { path: string, viewState: ViewState }
local function handle_view_change(data)
	if not data.viewState then
		return
	end

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
			vim.cmd("new")
			win = vim.api.nvim_get_current_win()
			return sync_window_layout(layout, win)
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
		vim.cmd("new")
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
					vim.cmd("vsplit")
				else
					vim.cmd("split")
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

	-- Release lock after 100ms delay
	vim.defer_fn(function()
		is_handling_message = false
		log("Message handling completed, lock released", vim.log.levels.DEBUG)
	end, 100)

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
					local null_index = message_buffer:find("\0")
					if not null_index then
						-- No end character found, wait for more data
						break
					end

					-- Extract a complete message
					local message_str = message_buffer:sub(1, null_index - 1)
					-- Update buffer, remove processed message
					message_buffer = message_buffer:sub(null_index + 1)

					if message_str == "" then
						goto continue
					end

					local ok, message = pcall(vim.json.decode, message_str)
					if ok then
						log("Received message: " .. message_str, vim.log.levels.DEBUG)
						-- Use vim.schedule to handle message
						vim.schedule(function()
							handle_message(message)
						end)
					else
						log("Failed to parse message: " .. message, vim.log.levels.ERROR)
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
	if not server then
		return
	end
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
		from_nvim = true,
	})
end

---Sync current buffer to VSCode
function M.sync_buffer()
	if not server then
		return
	end
	-- Skip sync if handling message
	if is_handling_message then
		log("Skipping buffer sync while handling message", vim.log.levels.DEBUG)
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	if should_ignore_buffer(buf) then
		return
	end

	local path = vim.api.nvim_buf_get_name(buf)
	if path == "" then
		return
	end

	log(string.format("Syncing buffer: %s", path), vim.log.levels.DEBUG)
	send_message({
		type = "buffer_change",
		data = {
			path = path,
		},
		from_nvim = true,
	})
end

return M
