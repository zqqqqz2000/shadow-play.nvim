-- 开发环境初始化文件
-- 确保卸载之前加载的插件
if package.loaded['shadow-play'] then
  package.loaded['shadow-play'] = nil
end

-- 添加当前目录到运行时路径
local function add_to_rtp()
  local rtp = vim.opt.rtp:get()
  local plugin_path = vim.fn.expand('$HOME/Documents/projects/shadow-play.nvim')
  if not vim.tbl_contains(rtp, plugin_path) then
    vim.opt.rtp:prepend(plugin_path)
  end
end

add_to_rtp()

-- 重新加载插件
require('shadow-play').setup(
    {
        debug = false,
    }
)