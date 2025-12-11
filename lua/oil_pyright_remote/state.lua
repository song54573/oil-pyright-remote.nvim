-- state.lua: 插件状态管理模块
-- 功能：集中管理所有可变状态，包括环境存储、重连状态、全局标记等
-- 设计原则：封装状态、避免全局变量、提供清晰的API

local M = {}

-- 依赖模块
local uv = vim.uv or vim.loop
local path = require("oil_pyright_remote.path")

-- 内部状态存储
local internal_state = {
  -- 环境存储相关
  env_store_loaded = false,
  env_store = {},
  valid_store_loaded = false,
  valid_store = {},

  -- 全局标记
  prompted_env = false,
  checked_env = nil,
  last_check_out = nil,

  -- 重连状态
  reconnect = {
    timer = nil,
    attempted = false,
    suppress_count = 0,
    last_buf = nil,
  },
}

-- 文件路径配置
local env_store_path = vim.fn.stdpath("data") .. "/pyright_remote_envs.json"
local valid_store_path = vim.fn.stdpath("data") .. "/pyright_remote_validated.json"

-----------------------------------------------------------------------
-- 辅助函数：安全执行 JSON 操作
-----------------------------------------------------------------------
local function safe_json_decode(data)
  local ok, result = pcall(vim.fn.json_decode, data)
  if ok then
    return result
  end
  return nil
end

local function safe_json_encode(data)
  local ok, result = pcall(vim.fn.json_encode, data)
  if ok then
    return result
  end
  return nil
end

-----------------------------------------------------------------------
-- 辅助函数：安全文件操作
-----------------------------------------------------------------------
local function safe_read_file(path)
  local ok, data = pcall(vim.fn.readfile, path)
  if ok and data and #data > 0 then
    return table.concat(data, "\n")
  end
  return nil
end

local function safe_write_file(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  pcall(vim.fn.mkdir, dir, "p")
  local ok = pcall(vim.fn.writefile, { content }, path)
  return ok
end

-----------------------------------------------------------------------
-- 环境存储相关函数
-----------------------------------------------------------------------

-- M.load_env_store()
-- 功能：加载环境存储数据
-- 返回：环境存储表
function M.load_env_store()
  if internal_state.env_store_loaded then
    return internal_state.env_store
  end

  internal_state.env_store_loaded = true
  internal_state.env_store = {}

  local data = safe_read_file(env_store_path)
  if data then
    local decoded = safe_json_decode(data)
    if type(decoded) == "table" then
      internal_state.env_store = decoded
    end
  end

  return internal_state.env_store
end

-- M.save_env_store()
-- 功能：保存环境存储数据到文件
function M.save_env_store()
  if not internal_state.env_store_loaded then
    return
  end

  local encoded = safe_json_encode(internal_state.env_store or {})
  if encoded then
    safe_write_file(env_store_path, encoded)
  end
end

-- M.list_envs(host)
-- 功能：列出指定主机的环境历史
-- 参数：host - 主机名，可选，默认使用当前配置的host
-- 返回：环境路径列表
function M.list_envs(host)
  local store = M.load_env_store()
  local config = require("oil_pyright_remote.config")
  local entry = store[host or config.get("host")]
  if entry and entry.envs then
    return entry.envs
  end
  return {}
end

-- M.remember_env(host, env)
-- 功能：记住环境路径到历史记录
-- 参数：
--   host - 主机名
--   env  - 环境路径
function M.remember_env(host, env)
  if not host or host == "" or not env or env == "" then
    return
  end

  env = path.normalize_env(env)
  local store = M.load_env_store()
  store[host] = store[host] or { envs = {}, last_env = nil }
  local entry = store[host]

  entry.last_env = env

  -- 移除已存在的条目
  local found
  for i, v in ipairs(entry.envs) do
    if v == env then
      found = i
      break
    end
  end
  if found then
    table.remove(entry.envs, found)
  end

  -- 添加到开头
  table.insert(entry.envs, 1, env)
  M.save_env_store()
end

-- M.has_valid_env(host, env)
-- 功能：检查环境是否已验证过
-- 参数：
--   host - 主机名
--   env  - 环境路径
-- 返回：布尔值
function M.has_valid_env(host, env)
  local config = require("oil_pyright_remote.config")
  host = host or config.get("host")
  env = path.normalize_env(env)

  if not host or host == "" or not env or env == "" then
    return false
  end

  local store = M.load_valid_store()
  return store[host] and store[host][env] == true
end

-- M.mark_valid_env(host, env)
-- 功能：标记环境为已验证
-- 参数：
--   host - 主机名
--   env  - 环境路径
function M.mark_valid_env(host, env)
  local config = require("oil_pyright_remote.config")
  host = host or config.get("host")
  env = path.normalize_env(env)

  if not host or host == "" or not env or env == "" then
    return
  end

  local store = M.load_valid_store()
  store[host] = store[host] or {}
  store[host][env] = true
  M.save_valid_store()
end

-- M.get_last_env(host)
-- 功能：获取主机最后使用的环境
-- 参数：host - 主机名，可选
-- 返回：环境路径或nil
function M.get_last_env(host)
  local config = require("oil_pyright_remote.config")
  local store = M.load_env_store()
  local entry = store[host or config.get("host")]
  if entry and entry.last_env and entry.last_env ~= "" then
    return path.normalize_env(entry.last_env)
  end
end

-- M.forget_env(host, env)
-- 功能：忘记环境记录
-- 参数：
--   host - 主机名
--   env  - 环境路径，可选；不提供则清除该主机所有记录
function M.forget_env(host, env)
  local config = require("oil_pyright_remote.config")
  host = host or config.get("host")

  if not host or host == "" then
    return
  end

  local store = M.load_env_store()
  if not store[host] then
    return
  end

  if not env or env == "" then
    -- 清除整个主机记录
    store[host] = nil
    local vstore = M.load_valid_store()
    vstore[host] = nil
    M.save_valid_store()
    M.save_env_store()
    return
  end

  -- 清除特定环境
  local entry = store[host]
  if entry.envs then
    for i, v in ipairs(entry.envs) do
      if v == env then
        table.remove(entry.envs, i)
        break
      end
    end
  end

  if entry.last_env == env then
    entry.last_env = entry.envs and entry.envs[1] or nil
  end

  if (not entry.envs or #entry.envs == 0) and not entry.last_env then
    store[host] = nil
  end

  local vstore = M.load_valid_store()
  if vstore[host] then
    vstore[host][env] = nil
    if vim.tbl_isempty(vstore[host]) then
      vstore[host] = nil
    end
    M.save_valid_store()
  end

  M.save_env_store()
end

-----------------------------------------------------------------------
-- 有效性存储相关函数
-----------------------------------------------------------------------

-- M.load_valid_store()
-- 功能：加载已验证环境存储
-- 返回：已验证环境存储表
function M.load_valid_store()
  if internal_state.valid_store_loaded then
    return internal_state.valid_store
  end

  internal_state.valid_store_loaded = true
  internal_state.valid_store = {}

  local data = safe_read_file(valid_store_path)
  if data then
    local decoded = safe_json_decode(data)
    if type(decoded) == "table" then
      internal_state.valid_store = decoded
    end
  end

  return internal_state.valid_store
end

-- M.save_valid_store()
-- 功能：保存已验证环境存储到文件
function M.save_valid_store()
  if not internal_state.valid_store_loaded then
    return
  end

  local encoded = safe_json_encode(internal_state.valid_store or {})
  if encoded then
    safe_write_file(valid_store_path, encoded)
  end
end

-----------------------------------------------------------------------
-- 全局状态标记函数
-----------------------------------------------------------------------

-- M.get_prompted_env()
-- 返回：是否已提示过环境
function M.get_prompted_env()
  return internal_state.prompted_env
end

-- M.set_prompted_env(value)
-- 参数：value - 布尔值
function M.set_prompted_env(value)
  internal_state.prompted_env = value == true
end

-- M.get_checked_env()
-- 返回：已检查的环境缓存键
function M.get_checked_env()
  return internal_state.checked_env
end

-- M.set_checked_env(value)
-- 参数：value - 环境缓存键或nil
function M.set_checked_env(value)
  internal_state.checked_env = value
end

-- M.get_last_check_out()
-- 返回：上次检查的输出
function M.get_last_check_out()
  return internal_state.last_check_out
end

-- M.set_last_check_out(value)
-- 参数：value - 检查输出
function M.set_last_check_out(value)
  internal_state.last_check_out = value
end

-----------------------------------------------------------------------
-- 重连状态相关函数
-----------------------------------------------------------------------

-- M.get_reconnect_state()
-- 返回：重连状态表
function M.get_reconnect_state()
  return internal_state.reconnect
end

-- M.stop_reconnect_timer()
-- 功能：停止重连计时器
function M.stop_reconnect_timer()
  local reconnect = internal_state.reconnect
  if reconnect.timer then
    reconnect.timer:stop()
    reconnect.timer:close()
    reconnect.timer = nil
  end
end

-- M.pick_reconnect_buf(client)
-- 功能：选择重连的目标缓冲区
-- 参数：client - LSP客户端对象，可选
-- 返回：缓冲区编号或nil
function M.pick_reconnect_buf(client)
  if client and client.attached_buffers then
    for buf, attached in pairs(client.attached_buffers) do
      if attached and vim.api.nvim_buf_is_valid(buf) then
        return buf
      end
    end
  end

  local reconnect = internal_state.reconnect
  if reconnect.last_buf and vim.api.nvim_buf_is_valid(reconnect.last_buf) then
    return reconnect.last_buf
  end
end

-- M.schedule_reconnect(bufnr, exit_code, signal)
-- 功能：调度重连
-- 参数：
--   bufnr     - 目标缓冲区
--   exit_code - 退出码
--   signal    - 退出信号
function M.schedule_reconnect(bufnr, exit_code, signal)
  local reconnect = internal_state.reconnect

  if reconnect.attempted then
    return
  end

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  reconnect.attempted = true
  M.stop_reconnect_timer()

  reconnect.timer = uv.new_timer()
  reconnect.timer:start(20000, 0, function()
    M.stop_reconnect_timer()
    vim.schedule(function()
      if reconnect.suppress_count > 0 then
        return
      end

      if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify("[pyright_remote] reconnect skipped: buffer no longer valid", vim.log.levels.WARN)
        return
      end

      vim.notify("[pyright_remote] LSP disconnected, retrying once ...", vim.log.levels.WARN)
      local ok, err = pcall(require("oil_pyright_remote").enable_pyright_remote, bufnr)
      if not ok then
        vim.notify("[pyright_remote] reconnect failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end)
  end)

  vim.notify(
    string.format(
      "[pyright_remote] LSP exited unexpectedly (code=%s, signal=%s). Retry in 20s ...",
      tostring(exit_code),
      tostring(signal)
    ),
    vim.log.levels.WARN
  )
end

-- M.pyright_on_exit(code, signal, client_id)
-- 功能：Pyright退出回调
-- 参数：
--   code      - 退出码
--   signal    - 退出信号
--   client_id - 客户端ID
function M.pyright_on_exit(code, signal, client_id)
  local reconnect = internal_state.reconnect

  if reconnect.suppress_count > 0 then
    reconnect.suppress_count = reconnect.suppress_count - 1
    return
  end

  if (code == 0 or code == nil) and (signal == 0 or signal == nil) then
    return
  end

  local client = client_id and vim.lsp.get_client_by_id and vim.lsp.get_client_by_id(client_id)

  -- 在fast event中需要调度到安全上下文
  if vim.in_fast_event() then
    vim.schedule(function()
      local target_buf = M.pick_reconnect_buf(client)
      if target_buf then
        M.schedule_reconnect(target_buf, code, signal)
      end
    end)
    return
  end

  local target_buf = M.pick_reconnect_buf(client)
  if target_buf then
    M.schedule_reconnect(target_buf, code, signal)
  end
end

-- M.set_reconnect_last_buf(bufnr)
-- 功能：设置重连的最后缓冲区
-- 参数：bufnr - 缓冲区编号
function M.set_reconnect_last_buf(bufnr)
  internal_state.reconnect.last_buf = bufnr
end

-- M.increment_suppress_count()
-- 功能：增加重连抑制计数
function M.increment_suppress_count()
  internal_state.reconnect.suppress_count = internal_state.reconnect.suppress_count + 1
end

-- M.reset_reconnect_attempted()
-- 功能：重置重连尝试状态
function M.reset_reconnect_attempted()
  internal_state.reconnect.attempted = false
end

-----------------------------------------------------------------------
-- 状态管理函数
-----------------------------------------------------------------------

-- M.reset()
-- 功能：重置所有状态（除持久化存储）
function M.reset()
  -- 重置标记
  internal_state.prompted_env = false
  internal_state.checked_env = nil
  internal_state.last_check_out = nil

  -- 重置重连状态
  M.stop_reconnect_timer()
  internal_state.reconnect = {
    timer = nil,
    attempted = false,
    suppress_count = 0,
    last_buf = nil,
  }
end

-- M.cleanup()
-- 功能：清理资源，退出时调用
function M.cleanup()
  M.stop_reconnect_timer()
  M.reset()
end

return M