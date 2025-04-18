---@type table<string, any>
local M = {}

-- Default configuration
---@type Config
local default_config = {
	auto_reload = true,
	sync_interval = 1000, -- Synchronization interval (milliseconds)
	socket_path = vim.fn.stdpath("data") .. "/shadow-play.sock",
	debug = false, -- 添加调试开关
	log_file = vim.fn.stdpath("cache") .. "/shadow-play.log", -- 日志文件路径
}

---@type Config
local config = default_config

-- 日志功能
local function log(msg, level)
	if not config.debug then
		return
	end
	level = level or "INFO"
	local log_msg = string.format("[%s][%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), level, msg)

	local file, err = io.open(config.log_file, "a")
	if not file then
		vim.notify(string.format("Failed to open log file: %s, error: %s", config.log_file, err), vim.log.levels.ERROR)
		return
	end

	local success, write_err = pcall(function()
		file:write(log_msg)
		file:close()
	end)

	if not success then
		vim.notify(string.format("Failed to write to log file: %s", write_err), vim.log.levels.ERROR)
	end
end

M.log = log

---Initialize the plugin with user configuration
---@param user_config Config|nil
function M.setup(user_config)
	-- Merge user configuration
	---@type Config
	config = vim.tbl_deep_extend("force", default_config, user_config or {})

	log("Plugin initialized with config: " .. vim.inspect(config))

	-- Create autocommand group
	local group = vim.api.nvim_create_augroup("ShadowPlay", { clear = true })

	-- Watch for tab changes
	vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufEnter" }, {
		group = group,
		callback = function()
			log("Tab change detected")
			require("shadow-play.sync").sync_wins()
		end,
	})

	-- Watch for file modifications
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = group,
		callback = function()
			log("Buffer write detected")
			require("shadow-play.sync").sync_buffer()
		end,
	})

	-- Watch for window scroll
	vim.api.nvim_create_autocmd({
		"CursorMoved",
		"CursorMovedI",
		"VimResized", -- 窗口大小改变时可能导致滚动
		"WinNew", -- 新窗口创建时
		"WinClosed", -- 窗口关闭时
		"WinEnter", -- 进入窗口时
		"TextChanged", -- 文本改变时（用于更新滚动位置）
		"TextChangedI", -- 插入模式下文本改变时
	}, {
		group = group,
		callback = function(ev)
			log("Window event detected: " .. ev.event)
			local ok, err = pcall(function()
				require("shadow-play.sync").sync_wins()
			end)
			if not ok then
				-- 记录详细错误信息
				log("Error in sync_view: " .. tostring(err), "ERROR")
				-- 同时显示错误通知
				vim.notify("ShadowPlay sync_view error: " .. tostring(err), vim.log.levels.ERROR)
				-- 记录调用栈
				log("Stack trace: " .. debug.traceback(), "ERROR")
			end
		end,
	})

	-- Initialize sync service
	require("shadow-play.sync").init(config)
end

return M
