-- config.lua: 配置管理模块
-- 功能：统一处理插件配置，支持 vim.g、环境变量、setup() 函数传入的配置
-- 设计原则：优先级：setup(opts) > vim.g.* > 环境变量 > 默认值
local M = {}

-- 默认配置
local defaults = {
  host = "",              -- 远程 SSH 主机
  env = "",               -- 远程虚拟环境路径
  root = "",              -- 远程工作区根目录
  auto_install = false,   -- 自动安装 pyright
  start_notify = false,   -- 启动时通知
}

-- 当前配置缓存
local current_config = vim.deepcopy(defaults)

-- 配置字段映射：环境变量名 -> 配置键
local env_mappings = {
  PYRIGHT_REMOTE_HOST = "host",
  PYRIGHT_REMOTE_ENV = "env",
  PYRIGHT_REMOTE_ROOT = "root",
}

-- vim.g 变量映射：vim.g 变量名 -> 配置键
local vim_g_mappings = {
  pyright_remote_host = "host",
  pyright_remote_env = "env",
  pyright_remote_workspace_root = "root",
  pyright_remote_auto_install = "auto_install",
  pyright_remote_start_notify = "start_notify",
}

-----------------------------------------------------------------------
-- load_from_env()
-- 功能：从环境变量加载配置
-- 返回：包含环境变量配置的表
-----------------------------------------------------------------------
local function load_from_env()
  local env_config = {}
  for env_var, config_key in pairs(env_mappings) do
    local value = vim.env[env_var]
    if value then
      env_config[config_key] = value
    end
  end
  return env_config
end

-----------------------------------------------------------------------
-- load_from_vim_g()
-- 功能：从 vim.g 变量加载配置
-- 返回：包含 vim.g 配置的表
-----------------------------------------------------------------------
local function load_from_vim_g()
  local g_config = {}
  for g_var, config_key in pairs(vim_g_mappings) do
    local value = vim.g[g_var]
    if value ~= nil then
      g_config[config_key] = value
    end
  end
  return g_config
end

-----------------------------------------------------------------------
-- normalize_value(key, value)
-- 功能：对特定配置值进行规范化处理
-- 参数：
--   key   : 配置键名
--   value : 原始值
-- 返回：规范化后的值
-----------------------------------------------------------------------
local function normalize_value(key, value)
  if value == nil then
    return nil
  end

  if key == "env" and type(value) == "string" then
    -- 引用 path 模块进行环境路径规范化
    local path = require("oil_pyright_remote.path")
    return path.normalize_env(value) or ""
  elseif key == "auto_install" or key == "start_notify" then
    -- 布尔值处理
    return value == true
  elseif type(value) == "string" then
    -- 字符串去除首尾空白
    return value:gsub("^%s+", ""):gsub("%s+$", "")
  end

  return value
end

-----------------------------------------------------------------------
-- update_vim_g(key, value)
-- 功能：更新对应的 vim.g 变量，保持向后兼容
-- 参数：
--   key   : 配置键名
--   value : 配置值
-----------------------------------------------------------------------
local function update_vim_g(key, value)
  -- 反向查找 vim.g 映射
  for g_var, config_key in pairs(vim_g_mappings) do
    if config_key == key then
      vim.g[g_var] = value
      break
    end
  end
end

-----------------------------------------------------------------------
-- M.get(key)
-- 功能：获取配置值
-- 参数：
--   key : 配置键名，可选；不提供则返回整个配置表
-- 返回：配置值或整个配置表
-----------------------------------------------------------------------
function M.get(key)
  if key then
    return current_config[key]
  end
  return vim.deepcopy(current_config)
end

-----------------------------------------------------------------------
-- M.set(updates)
-- 功能：更新配置
-- 参数：
--   updates : 包含要更新的配置的表
-- 示例：M.set({host = "example.com", env = "/path/to/venv"})
-----------------------------------------------------------------------
function M.set(updates)
  if type(updates) ~= "table" then
    error("set() 参数必须是表")
  end

  for key, value in pairs(updates) do
    if defaults[key] == nil then
      error(string.format("未知的配置项: %s", key))
    end

    local normalized = normalize_value(key, value)
    current_config[key] = normalized

    -- 更新 vim.g 变量保持兼容
    update_vim_g(key, normalized)
  end
end

-----------------------------------------------------------------------
-- M.setup(opts)
-- 功能：用户配置入口，类似传统的 setup 函数
-- 参数：
--   opts : 用户配置表
-- 用法：require("oil_pyright_remote").setup({...})
-----------------------------------------------------------------------
function M.setup(opts)
  opts = opts or {}
  M.set(opts)
end

-----------------------------------------------------------------------
-- M.reload()
-- 功能：重新加载配置（从环境变量和 vim.g）
-- 用途：当外部配置发生变化时，可以调用此函数刷新
-----------------------------------------------------------------------
function M.reload()
  -- 按优先级合并配置：默认值 -> 环境变量 -> vim.g -> 当前设置
  local env_config = load_from_env()
  local g_config = load_from_vim_g()

  -- 从默认值开始
  current_config = vim.deepcopy(defaults)

  -- 应用环境变量
  for key, value in pairs(env_config) do
    current_config[key] = normalize_value(key, value)
  end

  -- 应用 vim.g 变量（会覆盖环境变量）
  for key, value in pairs(g_config) do
    current_config[key] = normalize_value(key, value)
  end
end

-----------------------------------------------------------------------
-- M.validate()
-- 功能：验证当前配置的合理性
-- 返回：ok, message
--   ok      : 布尔值，配置是否有效
--   message : 字符串，错误信息或成功信息
-----------------------------------------------------------------------
function M.validate()
  local cfg = current_config

  -- host 不能为空（允许延迟设置，但给出警告）
  if not cfg.host or cfg.host == "" then
    return false, "远程主机名 (host) 未设置，请使用 :PyrightRemoteHost 或设置 PYRIGHT_REMOTE_HOST"
  end

  -- env 如果设置了必须是有效的路径格式
  if cfg.env and cfg.env ~= "" then
    local path = require("oil_pyright_remote.path")
    local normalized = path.normalize_env(cfg.env)
    if not normalized then
      return false, string.format("无效的虚拟环境路径: %s", cfg.env)
    end
  end

  -- root 如果设置了必须是绝对路径
  if cfg.root and cfg.root ~= "" and cfg.root:sub(1, 1) ~= "/" then
    return false, string.format("工作区根路径必须是绝对路径: %s", cfg.root)
  end

  return true, "配置验证通过"
end

-----------------------------------------------------------------------
-- M.is_ready()
-- 功能：检查是否已设置必要的配置项
-- 返回：布尔值，是否准备好启动 LSP
-----------------------------------------------------------------------
function M.is_ready()
  local ok, _ = M.validate()
  return ok and current_config.host ~= ""
end

-----------------------------------------------------------------------
-- M.get_state_for_lsp()
-- 功能：获取用于 LSP 启动的状态信息
-- 返回：包含 LSP 所需状态的表
-----------------------------------------------------------------------
function M.get_state_for_lsp()
  return {
    host = current_config.host,
    env = current_config.env,
    root = current_config.root,
    auto_install = current_config.auto_install,
    start_notify = current_config.start_notify,
  }
end

-- 初始化时加载配置
M.reload()

return M