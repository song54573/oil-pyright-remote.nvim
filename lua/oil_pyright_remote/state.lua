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
  env_validation_cache = {},
  env_validation_pending = {},
  env_list_cache = {},

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

-----------------------------------------------------------------------
-- 远程缓冲区判定（只对 oil-ssh:// 的 python 文件做重连）
-- 说明：
--   断网/重连场景下，如果我们对“当前随便一个 buffer”发起重连，会造成：
--   - 无意义的 ssh 连接尝试
--   - 触发诊断/通知的全局副作用（用户体感像 UI 坏了）
-- 因此重连必须只针对：python + oil-ssh:// 缓冲区。
-----------------------------------------------------------------------
local function is_remote_python_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if vim.bo[bufnr].filetype ~= "python" then
    return false
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  return type(name) == "string" and name:match("^oil%-ssh://[^/]+") ~= nil
end

-- 文件路径配置
local env_store_path = vim.fn.stdpath("data") .. "/pyright_remote_envs.json"
local valid_store_path = vim.fn.stdpath("data") .. "/pyright_remote_validated.json"
local ENV_VALIDATION_TTL_MS = 30000

local function now_ms()
  if uv and type(uv.now) == "function" then
    return uv.now()
  end
  return math.floor((vim.loop.hrtime() or 0) / 1000000)
end

local function shell_quote(str)
  return "'" .. tostring(str or ""):gsub("'", "'\\''") .. "'"
end

local function list_copy(items)
  return vim.deepcopy(items or {})
end

local function unique_normalized_envs(envs)
  local seen = {}
  local result = {}

  for _, env in ipairs(envs or {}) do
    local normalized = path.normalize_env(env)
    if normalized and normalized ~= "" and not seen[normalized] then
      seen[normalized] = true
      table.insert(result, normalized)
    end
  end

  return result
end

local function invalidate_env_list_cache(host)
  if not host or host == "" then
    return
  end
  internal_state.env_list_cache[host] = nil
end

local function clear_env_validation_cache_for_host(host)
  if not host or host == "" then
    return
  end

  for key, _ in pairs(internal_state.env_validation_cache) do
    if key:match("^" .. vim.pesc(host) .. "\n") then
      internal_state.env_validation_cache[key] = nil
    end
  end
end

local function set_env_validation_cache(host, env, valid)
  if not host or host == "" or not env or env == "" then
    return
  end

  internal_state.env_validation_cache[table.concat({ host, env }, "\n")] = {
    valid = valid == true,
    expires_at = now_ms() + ENV_VALIDATION_TTL_MS,
  }
end

local function get_env_validation_cache(host, env)
  if not host or host == "" or not env or env == "" then
    return nil
  end

  local entry = internal_state.env_validation_cache[table.concat({ host, env }, "\n")]
  if not entry then
    return nil
  end
  if entry.expires_at and entry.expires_at < now_ms() then
    internal_state.env_validation_cache[table.concat({ host, env }, "\n")] = nil
    return nil
  end
  return entry.valid
end

local function set_env_list_cache(host, envs)
  if not host or host == "" then
    return
  end

  internal_state.env_list_cache[host] = {
    envs = list_copy(envs),
    expires_at = now_ms() + ENV_VALIDATION_TTL_MS,
  }
end

local function get_env_list_cache(host)
  if not host or host == "" then
    return nil
  end

  local entry = internal_state.env_list_cache[host]
  if not entry then
    return nil
  end
  if entry.expires_at and entry.expires_at < now_ms() then
    internal_state.env_list_cache[host] = nil
    return nil
  end
  return list_copy(entry.envs)
end

local function purge_valid_env_entries(vstore, host, env)
  if type(vstore) ~= "table" or not host or host == "" or not env or env == "" then
    return false
  end

  local changed = false
  for key, envs in pairs(vstore) do
    if key == host or key:match(":" .. vim.pesc(host) .. "$") then
      if type(envs) == "table" and envs[env] ~= nil then
        envs[env] = nil
        changed = true
      end
      if type(envs) == "table" and vim.tbl_isempty(envs) then
        vstore[key] = nil
        changed = true
      end
    end
  end

  return changed
end

local function apply_validated_envs_for_host(host, valid_envs)
  if not host or host == "" then
    return {}
  end

  valid_envs = unique_normalized_envs(valid_envs)

  local store = M.load_env_store()
  local entry = store[host]
  local old_envs = entry and entry.envs or {}
  local old_last = entry and entry.last_env or nil
  local env_changed = false

  if entry then
    if not vim.deep_equal(old_envs, valid_envs) then
      entry.envs = valid_envs
      env_changed = true
    end

    if old_last and not vim.tbl_contains(valid_envs, path.normalize_env(old_last)) then
      entry.last_env = valid_envs[1] or nil
      env_changed = true
    elseif (not old_last or old_last == "") and valid_envs[1] then
      entry.last_env = valid_envs[1]
      env_changed = true
    end

    if #valid_envs == 0 and not entry.last_env then
      store[host] = nil
      env_changed = true
    end
  elseif #valid_envs > 0 then
    store[host] = {
      envs = valid_envs,
      last_env = valid_envs[1],
    }
    env_changed = true
  end

  local valid_set = {}
  for _, env in ipairs(valid_envs) do
    valid_set[env] = true
    set_env_validation_cache(host, env, true)
  end

  local vstore = M.load_valid_store()
  local valid_changed = false
  for _, env in ipairs(old_envs or {}) do
    local normalized = path.normalize_env(env)
    if normalized and not valid_set[normalized] then
      set_env_validation_cache(host, normalized, false)
      if purge_valid_env_entries(vstore, host, normalized) then
        valid_changed = true
      end
    end
  end

  if env_changed then
    M.save_env_store()
  end
  if valid_changed then
    M.save_valid_store()
  end

  set_env_list_cache(host, valid_envs)
  return valid_envs
end

local function prepare_host_envs(host)
  if not host or host == "" then
    return {}
  end

  local store = M.load_env_store()
  local entry = store[host]
  if not entry or type(entry.envs) ~= "table" then
    return {}
  end

  local normalized = unique_normalized_envs(entry.envs)
  local changed = not vim.deep_equal(normalized, entry.envs)

  if entry.last_env and entry.last_env ~= "" then
    local normalized_last = path.normalize_env(entry.last_env)
    if normalized_last ~= entry.last_env then
      entry.last_env = normalized_last
      changed = true
    end
  end

  if changed then
    entry.envs = normalized
    if #normalized == 0 and not entry.last_env then
      store[host] = nil
    end
    M.save_env_store()
  end

  return normalized
end

local function build_env_validation_script(envs)
  local lines = {
    "check_env() {",
    '  env_dir="$1"',
    '  py="$env_dir/bin/python"',
    '  if [ -x "$py" ] && "$py" -V >/dev/null 2>&1; then',
    '    printf \'OK\\t%s\\n\' "$env_dir"',
    "  fi",
    "}",
  }

  for _, env in ipairs(envs or {}) do
    table.insert(lines, "check_env " .. shell_quote(env))
  end

  return table.concat(lines, "\n")
end

local function parse_valid_env_lines(output)
  local valid = {}
  for _, line in ipairs(output or {}) do
    local env = type(line) == "string" and line:match("^OK\t(.+)$") or nil
    env = path.normalize_env(env)
    if env and env ~= "" then
      valid[env] = true
    end
  end
  return valid
end

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
    return list_copy(entry.envs)
  end
  return {}
end

-- M.get_validated_envs_async(host, cb, opts)
-- 功能：校验指定 host 的环境历史，仅保留 python 可执行的环境
-- 说明：
--   - 成功校验后会永久删除无效项，并落盘更新 env_store/valid_store
--   - SSH 失败/超时不会误删历史，只返回缓存或当前列表
function M.get_validated_envs_async(host, cb, opts)
  opts = opts or {}
  if type(cb) ~= "function" then
    error("get_validated_envs_async: cb 必须是函数")
  end

  local config = require("oil_pyright_remote.config")
  host = host or config.get("host")
  if not host or host == "" then
    cb({})
    return
  end

  if opts.force ~= true then
    local cached = get_env_list_cache(host)
    if cached then
      cb(cached)
      return
    end
  end

  internal_state.env_validation_pending[host] = internal_state.env_validation_pending[host] or {}
  table.insert(internal_state.env_validation_pending[host], cb)
  if #internal_state.env_validation_pending[host] > 1 then
    return
  end

  local envs = prepare_host_envs(host)
  if #envs == 0 then
    set_env_list_cache(host, {})
    local pending = internal_state.env_validation_pending[host] or {}
    internal_state.env_validation_pending[host] = nil
    for _, waiter in ipairs(pending) do
      pcall(waiter, {})
    end
    return
  end

  local cached_valids = {}
  local uncached_envs = {}
  for _, env in ipairs(envs) do
    local cached = get_env_validation_cache(host, env)
    if cached == true then
      cached_valids[env] = true
    elseif cached == nil or opts.force == true then
      table.insert(uncached_envs, env)
    end
  end

  local function finish(valid_set, persist)
    valid_set = valid_set or {}
    for env, ok in pairs(cached_valids) do
      if ok then
        valid_set[env] = true
      end
    end

    local valid_envs = {}
    for _, env in ipairs(envs) do
      if valid_set[env] then
        table.insert(valid_envs, env)
      end
    end

    if persist then
      valid_envs = apply_validated_envs_for_host(host, valid_envs)
    else
      set_env_list_cache(host, valid_envs)
    end

    local pending = internal_state.env_validation_pending[host] or {}
    internal_state.env_validation_pending[host] = nil
    for _, waiter in ipairs(pending) do
      pcall(waiter, list_copy(valid_envs))
    end
  end

  if #uncached_envs == 0 then
    finish(vim.deepcopy(cached_valids), true)
    return
  end

  local ssh_runner = require("oil_pyright_remote.ssh_runner")
  local script = build_env_validation_script(uncached_envs)
  local started = ssh_runner.execute_remote_script_on_host(host, script, function(ok, output)
    if not ok then
      local fallback = get_env_list_cache(host) or envs
      local pending = internal_state.env_validation_pending[host] or {}
      internal_state.env_validation_pending[host] = nil
      for _, waiter in ipairs(pending) do
        pcall(waiter, list_copy(fallback))
      end
      return
    end

    local valid_set = parse_valid_env_lines(output)
    for _, env in ipairs(uncached_envs) do
      set_env_validation_cache(host, env, valid_set[env] == true)
    end
    finish(valid_set, true)
  end, {
    timeout = opts.timeout or 15000,
    quiet = true,
    max_output_lines = math.max(32, #uncached_envs * 2),
  })

  if not started then
    local fallback = get_env_list_cache(host) or envs
    local pending = internal_state.env_validation_pending[host] or {}
    internal_state.env_validation_pending[host] = nil
    for _, waiter in ipairs(pending) do
      pcall(waiter, list_copy(fallback))
    end
  end
end

-- M.get_validated_envs(host, opts)
-- 功能：同步获取并清理指定 host 的有效环境列表
function M.get_validated_envs(host, opts)
  opts = opts or {}
  local done = false
  local result = {}
  local timeout = opts.timeout or 15000

  M.get_validated_envs_async(host, function(envs)
    result = envs or {}
    done = true
  end, opts)

  vim.wait(timeout + 100, function()
    return done
  end, 50, false)

  if done then
    return result
  end

  local cached = get_env_list_cache(host)
  if cached then
    return cached
  end
  return M.list_envs(host)
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
  invalidate_env_list_cache(host)
  set_env_validation_cache(host, env, true)
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
  env = path.normalize_env(env)

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
    purge_valid_env_entries(vstore, host, "__all__")
    for key, _ in pairs(vstore) do
      if key == host or key:match(":" .. vim.pesc(host) .. "$") then
        vstore[key] = nil
      end
    end
    clear_env_validation_cache_for_host(host)
    invalidate_env_list_cache(host)
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
  if purge_valid_env_entries(vstore, host, env) then
    M.save_valid_store()
  end

  invalidate_env_list_cache(host)
  set_env_validation_cache(host, env, false)
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
  local reconnect = internal_state.reconnect
  -- 优先使用“最后一次成功启用”的缓冲区（更符合用户直觉，也更稳定）
  if is_remote_python_buffer(reconnect.last_buf) then
    return reconnect.last_buf
  end

  -- 回退：从 client.attached_buffers 中挑一个“仍然有效的远程 python 缓冲区”
  -- 注意：pairs() 顺序不稳定，所以这里收集后排序，保证选择可预期。
  if client and client.attached_buffers then
    local candidates = {}
    for buf, attached in pairs(client.attached_buffers) do
      if attached and is_remote_python_buffer(buf) then
        table.insert(candidates, buf)
      end
    end
    table.sort(candidates)
    return candidates[1]
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

  -- 只对远程 python 缓冲区做重连（避免误伤当前其他文件类型）
  if not is_remote_python_buffer(bufnr) then
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

      if not is_remote_python_buffer(bufnr) then
        vim.notify("[pyright_remote] reconnect skipped: not a remote python buffer", vim.log.levels.WARN)
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
  internal_state.env_validation_cache = {}
  internal_state.env_validation_pending = {}
  internal_state.env_list_cache = {}

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
