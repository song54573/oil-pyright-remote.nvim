-- ui.lua: 用户界面和交互模块
-- 功能：处理诊断配置、按键映射、用户命令、主机列表、环境补全等
-- 设计原则：集中管理 UI 交互，提供清晰的配置接口

local M = {}

-- 依赖模块
local config = require("oil_pyright_remote.config")
local state = require("oil_pyright_remote.state")

-- 模块状态
local initialized = false
local user_command_deps = nil

-----------------------------------------------------------------------
-- M.apply_diagnostic_ui(opts)
-- 功能：应用诊断显示配置
-- 参数：opts - 配置选项（可选）
function M.apply_diagnostic_ui(opts)
  opts = opts or {}

  local diag_config = {
    virtual_text = { prefix = "●", spacing = 2 },
    signs = true,
    underline = true,
    update_in_insert = true, -- 插入模式也刷新诊断，及时看到错误
    severity_sort = true,
  }

  -- 合并用户选项
  if opts.diagnostic then
    diag_config = vim.tbl_deep_extend("force", diag_config, opts.diagnostic)
  end

  vim.diagnostic.config(diag_config)

  -- 设置诊断符号
  local diag_signs = opts.diagnostic_signs or { Error = "E", Warn = "W", Hint = "H", Info = "I" }
  for type, icon in pairs(diag_signs) do
    local hl = "DiagnosticSign" .. type
    vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" })
  end
end

-----------------------------------------------------------------------
-- M.setup_keymaps()
-- 功能：设置诊断相关按键映射
function M.setup_keymaps()
  vim.keymap.set("n", "<leader>e", function()
    vim.diagnostic.open_float(nil, { scope = "line" })
  end, { desc = "Line diagnostics" })
end

-----------------------------------------------------------------------
-- M.create_user_commands(deps)
-- 功能：创建所有用户命令
-- 参数：deps - 依赖表，包含重启函数等
function M.create_user_commands(deps)
  user_command_deps = deps or {}

  -- 诊断相关命令
  vim.api.nvim_create_user_command("DiagVirtualTextOn", function()
    M.apply_diagnostic_ui({
      diagnostic = { virtual_text = { prefix = "●", spacing = 2 }, signs = true }
    })
    vim.notify("[diagnostic] virtual text ON", vim.log.levels.INFO)
  end, { nargs = 0 })

  vim.api.nvim_create_user_command("DiagVirtualTextOff", function()
    vim.diagnostic.config({ virtual_text = false })
    vim.notify("[diagnostic] virtual text OFF", vim.log.levels.INFO)
  end, { nargs = 0 })

  -- 主机配置命令
  vim.api.nvim_create_user_command("PyrightRemoteHost", function(opts)
    if opts.args == "" then
      local cur = config.get("host") or "<unset>"
      vim.notify(string.format("[pyright_remote] current host: %s", cur), vim.log.levels.INFO)
      return
    end
    config.set({ host = opts.args })
    vim.notify(string.format("[pyright_remote] host -> %s", config.get("host")), vim.log.levels.INFO)
    if deps.maybe_restart then
      deps.maybe_restart()
    end
  end, { nargs = "?", complete = M.list_ssh_hosts })

  -- 环境配置命令
  vim.api.nvim_create_user_command("PyrightRemoteEnv", function(opts)
    if opts.args == "" then
      vim.notify(string.format("[pyright_remote] current env: %s", config.get("env")), vim.log.levels.INFO)
      return
    end
    config.set({ env = vim.fn.expand(opts.args) })
    vim.notify(string.format("[pyright_remote] env -> %s", config.get("env")), vim.log.levels.INFO)
    if deps.maybe_restart then
      deps.maybe_restart()
    end
  end, { nargs = "?", complete = function(arg_lead) return M.env_complete(arg_lead, deps.list_envs) end })

  -- 工作区根目录命令
  vim.api.nvim_create_user_command("PyrightRemoteRoot", function(opts)
    if opts.args == "" then
      vim.notify(string.format("[pyright_remote] current root: %s", config.get("root")), vim.log.levels.INFO)
      return
    end
    config.set({ root = vim.fn.expand(opts.args) })
    vim.notify(string.format("[pyright_remote] root -> %s", config.get("root")), vim.log.levels.INFO)
    if deps.maybe_restart then
      deps.maybe_restart()
    end
  end, { nargs = "?" })

  -- 重启命令
  vim.api.nvim_create_user_command("PyrightRemoteRestart", function()
    if deps.maybe_restart then
      deps.maybe_restart()
    end
  end, { nargs = 0 })

  -- 忘记环境命令
  vim.api.nvim_create_user_command("PyrightRemoteEnvForget", function(opts)
    local target = opts.args ~= "" and vim.fn.expand(opts.args) or nil
    state.forget_env(config.get("host"), target)
    if target then
      vim.notify(string.format("[pyright_remote] removed env %s for host %s", target, config.get("host")), vim.log.levels.INFO)
    else
      vim.notify(string.format("[pyright_remote] cleared env history for host %s", config.get("host")), vim.log.levels.INFO)
    end
  end, { nargs = "?", complete = function(arg_lead) return M.env_complete(arg_lead, deps.list_envs) end })
end

-----------------------------------------------------------------------
-- M.list_ssh_hosts(ArgLead, CmdLine, CursorPos)
-- 功能：列出 SSH 配置中的主机（用于命令补全）
-- 参数：标准 vim 命令补全参数
-- 返回：主机名列表
function M.list_ssh_hosts()
  local hosts = {}
  local ok, lines = pcall(vim.fn.readfile, vim.fn.expand("~/.ssh/config"))
  if not ok then
    return hosts
  end

  for _, line in ipairs(lines) do
    local h = line:match("^%s*Host%s+([%w%._%-]+)")
    if h and h ~= "*" and h ~= "?" then
      table.insert(hosts, h)
    end
  end

  return hosts
end

-----------------------------------------------------------------------
-- M.env_complete(arg_lead, list_envs_fn)
-- 功能：环境路径补全
-- 参数：
--   arg_lead      - 当前输入前缀
--   list_envs_fn - 列出环境的函数
-- 返回：匹配的环境路径列表
function M.env_complete(arg_lead, list_envs_fn)
  if type(list_envs_fn) ~= "function" then
    return {}
  end

  local res = {}
  local prefix = arg_lead or ""
  local esc = vim.pesc or function(s)
    return s:gsub("(%W)", "%%%1")
  end

  local envs = list_envs_fn(config.get("host")) or {}
  for _, env in ipairs(envs) do
    if env:find("^" .. esc(prefix)) then
      table.insert(res, env)
    end
  end

  return res
end

-----------------------------------------------------------------------
-- M.show_status()
-- 功能：显示当前配置状态
function M.show_status()
  local cfg = config.get()
  local status_lines = {
    "[pyright_remote] Current Configuration:",
    string.format("  Host: %s", cfg.host or "<unset>"),
    string.format("  Environment: %s", cfg.env or "<unset>"),
    string.format("  Root: %s", cfg.root or "<auto>"),
    string.format("  Auto-install: %s", tostring(cfg.auto_install)),
    string.format("  Start notify: %s", tostring(cfg.start_notify)),
  }

  local host = cfg.host
  local env = cfg.env
  if host and host ~= "" and env and env ~= "" then
    local valid = state.has_valid_env(host, env)
    table.insert(status_lines, string.format("  Environment validated: %s", tostring(valid)))
  end

  vim.notify(table.concat(status_lines, "\n"), vim.log.levels.INFO)
end

-----------------------------------------------------------------------
-- M.setup(opts)
-- 功能：初始化 UI 模块
-- 参数：opts - 配置选项，包含：
--          diagnostic: 诊断配置
--          diagnostic_signs: 诊断符号配置
--          keymaps: 是否设置按键映射
--          commands: 依赖函数表
function M.setup(opts)
  opts = opts or {}

  if initialized then
    return
  end

  -- 应用诊断 UI
  M.apply_diagnostic_ui(opts)

  -- 设置按键映射
  if opts.keymaps ~= false then
    M.setup_keymaps()
  end

  -- 创建用户命令
  if opts.commands then
    M.create_user_commands(opts.commands)
  end

  -- 创建状态显示命令（可选）
  if opts.status_command ~= false then
    vim.api.nvim_create_user_command("PyrightRemoteStatus", function()
      M.show_status()
    end, { nargs = 0 })
  end

  initialized = true
end

return M
