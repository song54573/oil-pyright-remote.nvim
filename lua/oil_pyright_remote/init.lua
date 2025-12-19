-- init.lua: 核心入口模块
-- 功能：装配各子模块，提供统一的初始化和配置接口
-- 设计原则：清晰的模块依赖、简单的初始化流程

local M = {}

-- 导入所有子模块
local config = require("oil_pyright_remote.config")
local state = require("oil_pyright_remote.state")
local path = require("oil_pyright_remote.path")
local ssh_runner = require("oil_pyright_remote.ssh_runner")
local installer = require("oil_pyright_remote.installer")
local lsp = require("oil_pyright_remote.lsp")
local ui = require("oil_pyright_remote.ui")
local diagnostics = require("oil_pyright_remote.diagnostics")

-- 模块状态
local initialized = false

-----------------------------------------------------------------------
-- M.setup(opts)
-- 功能：初始化插件
-- 参数：opts - 用户配置选项
-- 支持的配置项：
--   host: 远程主机名
--   env: 虚拟环境路径
--   root: 工作区根目录
--   auto_install: 自动安装 pyright
--   start_notify: 启动时通知
--   diagnostic: 诊断配置
--   diagnostic_signs: 诊断符号
--   capabilities: LSP 能力覆盖
function M.setup(opts)
  opts = opts or {}

  if initialized then
    return
  end

  -- 配置初始化（应用用户选项）
  config.setup(opts)

  -- 设置 URI 转换（支持 oil-ssh）
  local orig_uri_from_bufnr = vim.uri_from_bufnr
  vim.uri_from_bufnr = function(bufnr)
    return path.uri_from_bufnr(bufnr, orig_uri_from_bufnr)
  end

  -- 初始化 UI 模块
  ui.setup({
    diagnostic = opts.diagnostic,
    diagnostic_signs = opts.diagnostic_signs,
    keymaps = opts.keymaps,
    status_command = opts.status_command,
    commands = {
      maybe_restart = M.maybe_restart,
      list_envs = state.list_envs,
    },
  })

  -- 初始化诊断模块
  diagnostics.setup({
    signs = opts.diagnostic_signs,
    diagnostic = opts.diagnostic,
    commands = opts.commands,
    keymaps = opts.keymaps,
    jump_func = lsp.jump_with_oil,
  })

  -- 初始化 LSP 模块
  lsp.setup(opts.capabilities)

  -- 预热环境（如果配置了）
  local host = config.get("host")
  local env = config.get("env")
  if host and env then
    installer.prewarm_env_async(host, env)
  end

  initialized = true
end

-----------------------------------------------------------------------
-- M.enable_pyright_remote(bufnr)
-- 功能：为指定缓冲区启用 pyright_remote
-- 参数：bufnr - 缓冲区编号，可选
function M.enable_pyright_remote(bufnr)
  return lsp.enable_pyright_remote(bufnr)
end

-----------------------------------------------------------------------
-- M.maybe_restart(bufnr)
-- 功能：重启 LSP 客户端
-- 参数：bufnr - 缓冲区编号，可选
function M.maybe_restart(bufnr)
  return lsp.restart_client(bufnr)
end

-----------------------------------------------------------------------
-- M.get_status()
-- 功能：获取插件状态信息
-- 返回：状态表
function M.get_status()
  return {
    config = config.get(),
    initialized = initialized,
    has_valid_env = function()
      local cfg = config.get()
      return state.has_valid_env(cfg.backend .. ":" .. cfg.host, cfg.env)
    end,
  }
end

-----------------------------------------------------------------------
-- M.test_connection(cb)
-- 功能：测试 SSH 连接
-- 参数：cb - 回调函数 cb(success, message)
function M.test_connection(cb)
  ssh_runner.test_connection(cb)
end

-----------------------------------------------------------------------
-- M.cleanup()
-- 功能：清理资源
function M.cleanup()
  state.cleanup()
  ssh_runner.cleanup()
end

-- 注册清理钩子
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    -- 先清理浮窗再做通用清理，避免残留窗口
    installer.cleanup_floating_window()
    M.cleanup()
  end,
})

-- 导出子模块（用于高级用法或测试）
M.config = config
M.state = state
M.path = path
M.ssh_runner = ssh_runner
M.installer = installer
M.lsp = lsp
M.ui = ui
M.diagnostics = diagnostics

return M
