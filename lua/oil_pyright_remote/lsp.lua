-- lsp.lua: LSP 客户端管理模块
-- 功能：创建、管理和配置 pyright-langserver 远程客户端
-- 设计原则：严格的 filetype 过滤、清晰的客户端生命周期管理

local M = {}

-- 依赖模块
local config = require("oil_pyright_remote.config")
local state = require("oil_pyright_remote.state")
local path = require("oil_pyright_remote.path")
local ssh_runner = require("oil_pyright_remote.ssh_runner")
local installer = require("oil_pyright_remote.installer")
local diagnostics = require("oil_pyright_remote.diagnostics")

-- 模块状态
local initialized = false
local capabilities = nil
local native_mode = false
local native_config_registered = false
local native_config_enabled = false
local native_ready_buffers = {}
local remote_root_cache = {}
local pending_root_probes = {}
local runtime_cache = {}
local root_correction_once = {}
local stopping_clients = {}
local last_registered_runtime = nil
local cache_tick = 0

-- 支持的文件类型白名单（严格控制，避免错误附着）
local SUPPORTED_FILETYPES = { "python" }
local NATIVE_CONFIG_NAME = "pyright_remote"
local ROOT_CACHE_LIMIT = 128
local RUNTIME_CACHE_LIMIT = 64
local ROOT_CORRECTION_LIMIT = 128

local function next_cache_tick()
  cache_tick = cache_tick + 1
  return cache_tick
end

local function cache_get(cache, key)
  local entry = cache[key]
  if not entry then
    return nil
  end
  entry.at = next_cache_tick()
  return entry.value
end

local function cache_put(cache, key, value, limit)
  if not key then
    return
  end

  cache[key] = {
    value = value,
    at = next_cache_tick(),
  }

  local count = 0
  local oldest_key = nil
  local oldest_at = nil
  for cur_key, entry in pairs(cache) do
    count = count + 1
    if oldest_at == nil or entry.at < oldest_at then
      oldest_at = entry.at
      oldest_key = cur_key
    end
  end

  while limit and count > limit and oldest_key do
    cache[oldest_key] = nil
    count = count - 1
    oldest_key = nil
    oldest_at = nil
    for cur_key, entry in pairs(cache) do
      if oldest_at == nil or entry.at < oldest_at then
        oldest_at = entry.at
        oldest_key = cur_key
      end
    end
  end
end

-----------------------------------------------------------------------
-- 后端策略：不同 LSP 后端的配置生成策略
-- 说明：
--   - pyright: 使用 settings.python.analysis 配置格式
--   - ty: 使用 settings.ty.* 配置格式，静态项走 init_options
--   每个策略返回：{ cmd, settings?, init_options? }
-----------------------------------------------------------------------
local backend_strategies = {
  pyright = function(env_path)
    local user_opts = config.get("lsp_opts") or {}
    return {
      cmd = ssh_runner.build_pyright_cmd(),
      settings = {
        python = {
          analysis = vim.tbl_deep_extend("force", {
            typeCheckingMode = "basic",
            autoSearchPaths = true,
            useLibraryCodeForTypes = true,
            autoImportCompletions = true,
          }, user_opts),
          pythonPath = env_path .. "/bin/python",
        },
      },
    }
  end,

  ty = function(env_path)
    local user_opts = config.get("lsp_opts") or {}

    -- ty 的配置结构：settings.ty.*
    -- 参考: https://docs.astral.sh/ty/reference/editor-settings/
    local ty_settings = vim.tbl_deep_extend("force", {
      -- 【关键】不要禁用语言服务，否则诊断不工作
      disableLanguageServices = false,
      -- 诊断模式：远程 SSH 场景推荐 openFilesOnly 以提升性能
      diagnosticMode = "openFilesOnly",  -- "off" | "workspace" | "openFilesOnly"
      -- 显示语法错误诊断（关键配置）
      showSyntaxErrors = true,
      -- 【关键】规则配置：确保 invalid-syntax 不是 ignore
      configuration = {
        rules = {
          ["invalid-syntax"] = "error",  -- 语法错误显示为 error
        },
      },
      -- 内联类型提示
      inlayHints = {
        variableTypes = true,
        callArgumentNames = true,
      },
      -- 补全配置
      completions = {
        autoImport = true,
      },
    }, user_opts)

    return {
      cmd = ssh_runner.build_ty_cmd(),
      -- ty 使用 settings.ty.* 接收配置
      -- 参考: https://docs.astral.sh/ty/editors/
      settings = {
        ty = ty_settings,
      },
      -- init_options 仅用于静态配置（需要重启才能生效）
      init_options = {
        logLevel = "info",  -- "trace" | "debug" | "info" | "warn" | "error"
        -- 可选：将 ty server 日志写入文件以便调试
        -- logFile = vim.fn.stdpath("cache") .. "/ty-server.log",
      },
    }
  end,
}

-----------------------------------------------------------------------
-- 远程缓冲区判定（本插件只服务 oil-ssh:// 远程文件）
-- 说明：
--   - 本插件的 LSP 进程运行在远程主机，通过 ssh 传输 stdio
--   - 因此对于本地 python 文件，不应该启动/附着本客户端
--   - 这也是避免“重连后影响当前非 python 文件”的关键前置条件
-----------------------------------------------------------------------
local function get_oil_ssh_host_from_bufname(bufname)
  if type(bufname) ~= "string" or bufname == "" then
    return nil
  end
  -- 兼容两种形式：
  --   1) oil-ssh://host//abs/path
  --   2) oil-ssh://host/rel/or/abs
  return bufname:match("^oil%-ssh://([^/]+)")
end

local function is_remote_oil_ssh_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return get_oil_ssh_host_from_bufname(name) ~= nil
end

local function sync_host_from_bufnr(bufnr)
  local host = get_oil_ssh_host_from_bufname(vim.api.nvim_buf_get_name(bufnr))
  if host and host ~= "" then
    config.set({ host = host })
    return host
  end
  return config.get("host")
end

local function build_root_cache_key(host, base, markers)
  -- 任一关键维度缺失时不做缓存，避免生成不可控的 key
  if not host or host == "" then
    return nil
  end
  if not base or base == "" then
    return nil
  end
  markers = markers or {}

  -- 用不可见分隔符拼接，减少路径与 marker 发生碰撞的概率
  return table.concat({ host, base, table.concat(markers, "\0") }, "\n")
end

local function build_runtime_cache_key(host, env_path, backend_name, root_dir, lsp_opts)
  if not host or host == "" or not env_path or env_path == "" or not backend_name or backend_name == "" then
    return nil
  end
  if not root_dir or root_dir == "" then
    return nil
  end
  return table.concat({
    backend_name,
    host,
    env_path,
    root_dir,
    vim.inspect(lsp_opts or {}),
  }, "\n")
end

local function build_remote_root_script(remote_path, markers)
  local function esc(str)
    return (str or ""):gsub("'", "'\\''")
  end

  local quoted_markers = {}
  for _, marker in ipairs(markers or {}) do
    table.insert(quoted_markers, string.format([["%s"]], marker))
  end

  return string.format([[
p='%s'
while true; do
  for m in %s; do
    if [ -e "$p/$m" ]; then echo "$p"; exit 0; fi
  done
  parent="$(dirname "$p")"
  if [ "$parent" = "$p" ] || [ "$p" = "/" ]; then break; fi
  p="$parent"
done
exit 1
]], esc(vim.fn.fnamemodify(remote_path, ":p")), table.concat(quoted_markers, " "))
end

local function get_root_resolution_for_buf(bufnr, cfg)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local remote_path = path.from_oil_path(bufname) or vim.fn.fnamemodify(bufname, ":p")
  local base = vim.fn.fnamemodify(remote_path, ":p:h")
  local host = config.get("host")

  local root_dir = config.get("root")
  if root_dir and root_dir ~= "" then
    return {
      root_dir = root_dir,
      base_dir = base,
      remote_path = remote_path,
      pinned = true,
      resolved = true,
      probe_key = nil,
      markers = {},
    }
  end

  local markers = cfg.root_markers or M.get_default_config().root_markers or {}
  local probe_key = build_root_cache_key(host, base, markers)
  local cached = probe_key and cache_get(remote_root_cache, probe_key) or nil

  return {
    root_dir = cached or base,
    base_dir = base,
    remote_path = remote_path,
    pinned = false,
    resolved = cached ~= nil,
    probe_key = probe_key,
    markers = markers,
  }
end

local function request_remote_root_probe(root_info, cb)
  if type(cb) ~= "function" then
    return nil
  end

  if not root_info or root_info.pinned or root_info.resolved then
    vim.schedule(function()
      cb(root_info and root_info.root_dir or nil)
    end)
    return root_info and root_info.probe_key or nil
  end

  local probe_key = root_info.probe_key
  if not probe_key then
    vim.schedule(function()
      cb(root_info.base_dir)
    end)
    return nil
  end

  local cached = cache_get(remote_root_cache, probe_key)
  if cached then
    vim.schedule(function()
      cb(cached)
    end)
    return probe_key
  end

  pending_root_probes[probe_key] = pending_root_probes[probe_key] or {}
  table.insert(pending_root_probes[probe_key], cb)
  if #pending_root_probes[probe_key] > 1 then
    return probe_key
  end

  local started = ssh_runner.execute_remote_script(
    build_remote_root_script(root_info.remote_path, root_info.markers),
    function(ok, output)
      local root = ok and output and output[1] or nil
      if root and root ~= "" then
        cache_put(remote_root_cache, probe_key, root, ROOT_CACHE_LIMIT)
      end

      local waiters = pending_root_probes[probe_key] or {}
      pending_root_probes[probe_key] = nil
      for _, waiter in ipairs(waiters) do
        pcall(waiter, root)
      end
    end,
    { timeout = 8000, quiet = true, max_output_lines = 16 }
  )

  if not started then
    local waiters = pending_root_probes[probe_key] or {}
    pending_root_probes[probe_key] = nil
    vim.schedule(function()
      for _, waiter in ipairs(waiters) do
        pcall(waiter, nil)
      end
    end)
  end

  return probe_key
end

-----------------------------------------------------------------------
-- 辅助函数：检查缓冲区是否为支持的文件类型
-----------------------------------------------------------------------
local function is_supported_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  -- 双重约束：
  -- 1) 必须是 python
  -- 2) 必须是 oil-ssh:// 远程缓冲区（防止对本地文件误附着/误诊断）
  return vim.tbl_contains(SUPPORTED_FILETYPES, ft) and is_remote_oil_ssh_buffer(bufnr)
end

-----------------------------------------------------------------------
-- 辅助函数：获取 LSP 客户端（兼容不同 Neovim 版本）
-----------------------------------------------------------------------
local function get_lsp_clients(opts)
  -- 统一 opts 为表，避免后续多次判断 nil，逻辑更清晰
  opts = opts or {}

  -- 新 API：Neovim 0.10+ 提供 get_clients，支持 name/bufnr 过滤且不会触发弃用提示
  -- 只要存在就直接使用，保证在新版上不再调用已弃用的 get_active_clients
  if type(vim.lsp.get_clients) == "function" then
    return vim.lsp.get_clients(opts)
  end

  -- 旧版兼容：缺少 get_clients 时，退回 get_active_clients 手动过滤
  -- 这里的过滤逻辑与 get_clients 的行为对齐，保证语义一致
  local get_active = vim.lsp.get_active_clients
  if type(get_active) ~= "function" then
    return {}
  end

  local clients = {}
  local want_name = opts.name
  local want_bufnr = opts.bufnr
  for _, c in ipairs(get_active()) do
    -- 过滤规则：
    -- 1) name 不传则不过滤；传了就必须匹配客户端名称
    -- 2) bufnr 不传则不过滤；传了就必须已附着到该缓冲区
    local ok_name = (want_name == nil) or (c.name == want_name)
    local ok_buf = (want_bufnr == nil) or vim.lsp.buf_is_attached(want_bufnr, c.id)
    if ok_name and ok_buf then
      clients[#clients + 1] = c
    end
  end
  return clients
end

local function is_native_lsp_available()
  return type(vim.lsp.config) == "table" and type(vim.lsp.enable) == "function"
end

local function build_ready_key(host, env_path, backend_name)
  if not host or host == "" or not env_path or env_path == "" or not backend_name or backend_name == "" then
    return nil
  end
  return table.concat({ backend_name, host, env_path }, "\n")
end

local function current_ready_key_for_buf(bufnr)
  local host = get_oil_ssh_host_from_bufname(vim.api.nvim_buf_get_name(bufnr)) or config.get("host")
  return build_ready_key(host, config.get("env"), config.get("backend"))
end

local function mark_buf_ready(bufnr)
  local key = current_ready_key_for_buf(bufnr)
  if key then
    native_ready_buffers[bufnr] = key
  end
  return key
end

local function clear_buf_ready(bufnr)
  native_ready_buffers[bufnr] = nil
end

local function is_buf_ready_for_native(bufnr)
  local expected = native_ready_buffers[bufnr]
  local current = current_ready_key_for_buf(bufnr)
  if expected and current and expected == current then
    return true
  end
  native_ready_buffers[bufnr] = nil
  return false
end

-----------------------------------------------------------------------
-- stop_lsp_client(target, force)
-- 功能：兼容新旧 Neovim 的 LSP 停止 API
-----------------------------------------------------------------------
local function stop_lsp_client(target, force)
  local client = target
  local client_id = nil

  if type(target) == "number" then
    client_id = target
    client = vim.lsp.get_client_by_id and vim.lsp.get_client_by_id(target) or nil
  elseif type(target) == "table" then
    client_id = target.id
  end

  local stop_phase = client_id and stopping_clients[client_id] or nil
  local is_stopped = type(client) == "table" and type(client.is_stopped) == "function" and client:is_stopped() or false
  local is_stopping = type(client) == "table" and type(client.is_stopping) == "function" and client:is_stopping() or false

  if is_stopped then
    if client_id then
      stopping_clients[client_id] = nil
    end
    return true, false
  end

  if force ~= true and (stop_phase ~= nil or is_stopping) then
    return true, false
  end
  if force == true and stop_phase == "forced" then
    return true, false
  end

  if client and type(client.stop) == "function" then
    local ok = pcall(client.stop, client, force == true)
    if ok then
      if client_id then
        stopping_clients[client_id] = force == true and "forced" or "graceful"
      end
      return true, true
    end
  end

  if client_id and type(vim.lsp.stop_client) == "function" then
    local ok = pcall(vim.lsp.stop_client, client_id, force == true)
    if ok then
      stopping_clients[client_id] = force == true and "forced" or "graceful"
      return true, true
    end
  end

  return false, false
end

local function should_reuse_client(client, client_config)
  if not client or not client_config then
    return false
  end

  if client.name ~= client_config.name then
    return false
  end

  if client.id and stopping_clients[client.id] ~= nil then
    return false
  end

  if type(client.is_stopping) == "function" and client:is_stopping() then
    return false
  end

  if type(client.is_stopped) == "function" and client:is_stopped() then
    return false
  end

  local existing = client.config or {}
  return existing.root_dir == client_config.root_dir
    and existing._pyright_remote_host == client_config._pyright_remote_host
end

local function build_runtime_snapshot(host, env_path, backend_name, root_dir)
  local strategy = backend_strategies[backend_name] or backend_strategies.pyright
  local backend_config = strategy(env_path)
  return {
    host = host,
    env = env_path,
    backend = backend_name,
    root_dir = root_dir,
    workspace_folders = {
      {
        uri = vim.uri_from_fname(root_dir),
        name = root_dir,
      },
    },
    backend_config = backend_config,
  }
end

local function build_runtime_for_buf(bufnr, cfg)
  if not is_supported_buffer(bufnr) then
    error("build_runtime_for_buf: unsupported filetype for buffer " .. bufnr)
  end

  cfg = cfg or M.get_default_config()

  local host = sync_host_from_bufnr(bufnr)
  if not host or host == "" then
    error("build_runtime_for_buf: host is empty")
  end

  local env_path = config.get("env")
  if not env_path or env_path == "" then
    error("build_runtime_for_buf: env is empty")
  end

  local backend_name = config.get("backend")
  local root_info = get_root_resolution_for_buf(bufnr, cfg)
  local cache_key = build_runtime_cache_key(host, env_path, backend_name, root_info.root_dir, config.get("lsp_opts"))
  local cached = cache_key and cache_get(runtime_cache, cache_key) or nil
  local runtime = cached or build_runtime_snapshot(host, env_path, backend_name, root_info.root_dir)

  if cache_key and not cached then
    cache_put(runtime_cache, cache_key, runtime, RUNTIME_CACHE_LIMIT)
  end

  return {
    host = runtime.host,
    env = runtime.env,
    backend = runtime.backend,
    root_dir = runtime.root_dir,
    workspace_folders = runtime.workspace_folders,
    backend_config = runtime.backend_config,
    root_info = root_info,
    cache_key = cache_key,
  }
end

local function build_client_config_from_runtime(bufnr, cfg, runtime)
  local merged = vim.tbl_deep_extend("force", {}, cfg, {
    name = NATIVE_CONFIG_NAME,
    on_attach = M.on_attach,
    capabilities = capabilities,
    bufnr = bufnr,
    root_dir = runtime.root_dir,
    workspace_folders = runtime.workspace_folders,
    handlers = M.handlers,
    _pyright_remote_host = runtime.host,
  }, runtime.backend_config)

  if vim.g.pyright_remote_debug then
    vim.notify(
      string.format(
        "[pyright_remote] LSP Config Debug:\n  Backend: %s\n  Root: %s\n  Settings: %s\n  Init Options: %s",
        runtime.backend,
        merged.root_dir,
        vim.inspect(merged.settings or {}),
        vim.inspect(merged.init_options or {})
      ),
      vim.log.levels.INFO
    )
  end

  return merged
end

local function find_reusable_client(bufnr, client_config)
  for _, client in ipairs(M.get_clients({ name = NATIVE_CONFIG_NAME })) do
    if should_reuse_client(client, client_config) then
      if not vim.lsp.buf_is_attached(bufnr, client.id) then
        vim.lsp.buf_attach_client(bufnr, client.id)
      end
      state.reset_reconnect_attempted()
      return client.id
    end
  end
end

local function start_client_for_buf(bufnr, client_config)
  local reused = find_reusable_client(bufnr, client_config)
  if reused then
    return reused
  end

  if config.get("start_notify") then
    vim.schedule(function()
      pcall(
        vim.notify,
        string.format(
          "[pyright_remote] starting. root=%s file=%s",
          tostring(client_config.root_dir),
          vim.api.nvim_buf_get_name(bufnr)
        ),
        vim.log.levels.INFO
      )
    end)
  end

  local client_id = vim.api.nvim_buf_call(bufnr, function()
    return vim.lsp.start(client_config, {
      bufnr = bufnr,
      reuse_client = should_reuse_client,
    })
  end)

  if client_id then
    state.reset_reconnect_attempted()
  end
  return client_id
end

local function refresh_native_registered_config(runtime)
  if not native_mode or not native_config_registered then
    return
  end

  local registered = vim.lsp.config and vim.lsp.config[NATIVE_CONFIG_NAME]
  if not registered then
    return
  end

  local snapshot = {
    cmd = runtime.backend_config.cmd,
    settings = runtime.backend_config.settings or {},
    init_options = runtime.backend_config.init_options or {},
    workspace_folders = runtime.workspace_folders,
    host = runtime.host,
  }
  if last_registered_runtime and vim.deep_equal(last_registered_runtime, snapshot) then
    return
  end

  last_registered_runtime = vim.deepcopy(snapshot)
  registered.cmd = vim.deepcopy(runtime.backend_config.cmd)
  registered.settings = vim.deepcopy(runtime.backend_config.settings or {})
  registered.init_options = vim.deepcopy(runtime.backend_config.init_options or {})
  registered.workspace_folders = vim.deepcopy(runtime.workspace_folders)
  registered._pyright_remote_host = runtime.host
end

local function build_native_client_config(bufnr, runtime)
  local base = {}
  if vim.lsp.config and vim.lsp.config[NATIVE_CONFIG_NAME] then
    base = vim.deepcopy(vim.lsp.config[NATIVE_CONFIG_NAME])
  else
    base = vim.deepcopy(M.get_default_config())
  end
  return build_client_config_from_runtime(bufnr, base, runtime)
end

local function apply_hover_window_style(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end

  local ok, current = pcall(vim.api.nvim_get_option_value, "winhighlight", { win = winid })
  if not ok then
    return
  end

  local highlight = current or ""
  if highlight:find("FloatBorder:", 1, true) then
    return
  end

  if highlight ~= "" then
    highlight = highlight .. ","
  end
  highlight = highlight .. "FloatBorder:DiagnosticInfo"
  pcall(vim.api.nvim_set_option_value, "winhighlight", highlight, { win = winid })
end

local function hover_handler(err, result, ctx, config_override)
  local handler = vim.lsp.handlers.hover
  local columns = tonumber(vim.o.columns) or 120
  local lines = tonumber(vim.o.lines) or 40
  local merged = vim.tbl_deep_extend("force", {
    border = "single",
    max_width = math.max(60, math.floor(columns * 0.5)),
    max_height = math.max(8, math.floor(lines * 0.3)),
  }, config_override or {})

  local _, winid = handler(err, result, ctx, merged)
  apply_hover_window_style(winid)
  return _, winid
end

function M.hover(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local clients = M.get_clients({ bufnr = bufnr, name = NATIVE_CONFIG_NAME })
  if not clients or #clients == 0 then
    return vim.lsp.buf.hover()
  end

  local client = clients[1]
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding or "utf-16")
  vim.lsp.buf_request(bufnr, "textDocument/hover", params, hover_handler)
end

local function restart_for_root_correction(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local clients = M.get_clients({ name = NATIVE_CONFIG_NAME })
  if clients and #clients > 0 then
    local initiated_stop = false
    for _, client in ipairs(clients) do
      local _, initiated = stop_lsp_client(client, false)
      initiated_stop = initiated_stop or initiated
    end
    if initiated_stop then
      state.increment_suppress_count()
    end
  end

  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      M.kick_existing_python()
    end
  end)
end

local function ensure_root_resolution_for_runtime(bufnr, runtime)
  local root_info = runtime and runtime.root_info
  if not root_info or root_info.pinned or root_info.resolved then
    return
  end

  request_remote_root_probe(root_info, function(root)
    local resolved = root and root ~= "" and root or root_info.base_dir
    if resolved == runtime.root_dir then
      return
    end

    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) or not is_supported_buffer(bufnr) then
      return
    end

    local correction_key = table.concat({
      tostring(runtime.backend),
      tostring(runtime.host),
      tostring(runtime.env),
      tostring(runtime.root_dir),
      tostring(resolved),
    }, "\n")
    if cache_get(root_correction_once, correction_key) then
      return
    end

    local attached = M.get_clients({ bufnr = bufnr, name = NATIVE_CONFIG_NAME })
    if not attached or #attached == 0 then
      return
    end
    if attached[1].config and attached[1].config.root_dir == resolved then
      return
    end

    cache_put(root_correction_once, correction_key, true, ROOT_CORRECTION_LIMIT)
    restart_for_root_correction(bufnr)
  end)
end

local function clear_ready_buffers_for_client(client_id)
  local client = client_id and vim.lsp.get_client_by_id and vim.lsp.get_client_by_id(client_id) or nil
  if client and client.attached_buffers then
    for bufnr, _ in pairs(client.attached_buffers) do
      clear_buf_ready(bufnr)
    end
  end

  for bufnr, _ in pairs(native_ready_buffers) do
    if not vim.api.nvim_buf_is_valid(bufnr) then
      native_ready_buffers[bufnr] = nil
    end
  end
end

local function run_client_exit_cleanup(code, signal, client_id)
  if client_id then
    stopping_clients[client_id] = nil
  end
  diagnostics.cleanup_client(client_id)
  clear_ready_buffers_for_client(client_id)

  local clients = M.get_clients({ name = NATIVE_CONFIG_NAME })
  if not clients or #clients == 0 then
    last_registered_runtime = nil
  end

  state.pyright_on_exit(code, signal, client_id)
end

local function handle_client_exit(code, signal, client_id)
  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(function()
      run_client_exit_cleanup(code, signal, client_id)
    end)
    return
  end

  run_client_exit_cleanup(code, signal, client_id)
end

-----------------------------------------------------------------------
-- M.on_attach(client, bufnr)
-- 功能：LSP 客户端附着回调
-- 参数：
--   client - LSP 客户端对象
--   bufnr  - 缓冲区编号
-- 特点：严格检查 filetype，仅处理 python 文件
function M.on_attach(client, bufnr)
  -- 严格检查：只处理支持的文件类型
  if not is_supported_buffer(bufnr) then
    return
  end

  local bufmap = function(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
  end

  -- 基础 LSP 键映射
  bufmap("n", "gd", vim.lsp.buf.definition, "Go to definition")
  bufmap("n", "K", function()
    M.hover(bufnr)
  end, "Hover")
  bufmap("n", "gr", vim.lsp.buf.references, "References")
  bufmap("n", "<leader>rn", vim.lsp.buf.rename, "Rename")
  bufmap("n", "<leader>ac", vim.lsp.buf.code_action, "Code action")

  -- pyright_remote 特殊处理
  if client.name == "pyright_remote" then
    -- 禁用格式化（通常由其他插件处理）
    client.server_capabilities.documentFormattingProvider = false

    -- 配置诊断显示（只作用于 pyright_remote 的诊断命名空间，避免污染全局）
    diagnostics.apply_on_attach(client, bufnr)

    -- 诊断相关按键（buffer-local），避免影响非远程缓冲区
    bufmap("n", "<leader>e", diagnostics.open_diagnostic_float, "Line diagnostics")
    bufmap("n", "[d", diagnostics.goto_prev_diagnostic, "Previous diagnostic")
    bufmap("n", "]d", diagnostics.goto_next_diagnostic, "Next diagnostic")

    -- 自定义跳转处理器，确保使用 oil 路径
    local function req(method)
      return function()
        local name = vim.api.nvim_buf_get_name(bufnr)
        local h = get_oil_ssh_host_from_bufname(name)
        if h and h ~= "" then
          config.set({ host = h })
        end
        local params = vim.lsp.util.make_position_params(0, client.offset_encoding or "utf-16")
        vim.lsp.buf_request(bufnr, method, params, M.handlers[method] or M.jump_with_oil)
      end
    end

    bufmap("n", "gd", req("textDocument/definition"), "Go to definition (remote)")
    bufmap("n", "gi", req("textDocument/implementation"), "Go to implementation (remote)")
    bufmap("n", "gD", req("textDocument/declaration"), "Go to declaration (remote)")
    bufmap("n", "gr", req("textDocument/references"), "References (remote)")
  end
end

-----------------------------------------------------------------------
-- M.get_clients(opts)
-- 功能：获取 LSP 客户端列表
-- 参数：opts - 过滤选项（可选）
-- 返回：客户端列表
function M.get_clients(opts)
  return get_lsp_clients(opts)
end

-----------------------------------------------------------------------
-- M.build_config(bufnr)
-- 功能：构建 LSP 客户端配置
-- 参数：bufnr - 缓冲区编号
-- 返回：配置表
function M.build_config(bufnr)
  local base = vim.deepcopy(M.get_default_config())
  local runtime = build_runtime_for_buf(bufnr, base)
  return build_client_config_from_runtime(bufnr, base, runtime)
end

-----------------------------------------------------------------------
-- M.stop_client_force(client_id, timeout_ms)
-- 功能：强制停止 LSP 客户端（先尝试正常停止，超时后强制终止）
-- 参数：
--   client_id  - 客户端 ID
--   timeout_ms - 超时时间（毫秒），默认 3000
-- 说明：
--   - 系统休眠/网络断开后，vim.lsp.stop_client 可能无法正常终止进程
--   - 此函数确保客户端被彻底清理，避免僵尸进程和内存泄漏
-----------------------------------------------------------------------
function M.stop_client_force(client_id, timeout_ms)
  timeout_ms = timeout_ms or 3000

  if not client_id or client_id <= 0 then
    return
  end

  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    return
  end

  -- 清理诊断信息
  diagnostics.cleanup_client(client_id)

  -- 尝试正常停止
  stop_lsp_client(client, false)

  -- 等待客户端退出，超时后强制终止
  vim.defer_fn(function()
    local still_alive = vim.lsp.get_client_by_id(client_id)
    if still_alive then
      -- 客户端仍然存活，强制停止
      stop_lsp_client(still_alive, true)

      -- 如果有 RPC 进程，尝试强杀
      if still_alive.rpc and still_alive.rpc.pid then
        local uv = vim.uv or vim.loop
        if uv and uv.kill then
          pcall(uv.kill, still_alive.rpc.pid, "sigkill")
        end
      end
    end
  end, timeout_ms)
end

-----------------------------------------------------------------------
-- M.enable_pyright_remote(bufnr)
-- 功能：为指定缓冲区启用 pyright_remote
-- 参数：bufnr - 缓冲区编号，可选
function M.enable_pyright_remote(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- 严格检查：只处理支持的文件类型
  if not is_supported_buffer(bufnr) then
    return
  end

  -- 更新重连状态
  state.set_reconnect_last_buf(bufnr)
  state.stop_reconnect_timer()

  -- 若当前缓冲区已附着到 pyright_remote，则无需重复操作
  local attached = M.get_clients({ bufnr = bufnr, name = "pyright_remote" })
  if attached and #attached > 0 then
    return
  end

  sync_host_from_bufnr(bufnr)

  local function start_client()
    -- 防御性检查：缓冲区已被关闭的边缘情况（重连期间用户可能关闭了原文件）
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
      return nil
    end

    mark_buf_ready(bufnr)

    local ok_runtime, runtime = pcall(build_runtime_for_buf, bufnr, M.get_default_config())
    if not ok_runtime then
      clear_buf_ready(bufnr)
      vim.notify("[pyright_remote] runtime build failed: " .. tostring(runtime), vim.log.levels.ERROR)
      return nil
    end

    if native_mode then
      refresh_native_registered_config(runtime)
      local client_id = start_client_for_buf(bufnr, build_native_client_config(bufnr, runtime))
      if client_id then
        ensure_root_resolution_for_runtime(bufnr, runtime)
      end
      return client_id
    end

    local client_id = start_client_for_buf(
      bufnr,
      build_client_config_from_runtime(bufnr, vim.deepcopy(M.get_default_config()), runtime)
    )
    if client_id then
      ensure_root_resolution_for_runtime(bufnr, runtime)
    end
    return client_id
  end

  -- 确保环境配置正确
  installer.ensure_env_and_pyright_async(function(ok)
    if ok then
      start_client()
    else
      clear_buf_ready(bufnr)
    end
  end)
end

-----------------------------------------------------------------------
-- M.kick_existing_python()
-- 功能：为所有已加载的 Python 缓冲区启动客户端
function M.kick_existing_python()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and is_supported_buffer(buf) then
      pcall(M.enable_pyright_remote, buf)
    end
  end
end

-----------------------------------------------------------------------
-- M.restart_client(bufnr)
-- 功能：重启指定缓冲区的 LSP 客户端
-- 参数：bufnr - 缓冲区编号，可选
function M.restart_client(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  -- 停止重连计时器
  state.stop_reconnect_timer()

  -- 停止现有客户端
  local clients = M.get_clients({ name = "pyright_remote" })
  if clients and #clients > 0 then
    local initiated_stop = false
    for _, c in ipairs(clients) do
      local _, initiated = stop_lsp_client(c, false)
      initiated_stop = initiated_stop or initiated
    end
    if initiated_stop then
      state.increment_suppress_count()
    end
  end

  -- 启动新客户端
  M.enable_pyright_remote(bufnr)
end

-----------------------------------------------------------------------
-- M.get_default_config()
-- 功能：获取默认的 pyright_remote 配置（通用部分，不包含 backend 特定配置）
-- 返回：配置表
function M.get_default_config()
  return {
    name = NATIVE_CONFIG_NAME,

    -- 严格控制文件类型
    filetypes = SUPPORTED_FILETYPES,

    -- 工作区根标记（参考 nvim-lspconfig 的 ty 配置）
    root_markers = {
      "ty.toml",           -- ty 专用配置文件
      "pyproject.toml",    -- Python 项目标准
      "setup.py",
      "setup.cfg",
      "requirements.txt",
      ".git",
    },

    -- 初始化前处理
    before_init = function(params, config)
      params.processId = vim.NIL
    end,

    -- 退出回调
    on_exit = function(code, signal, client_id)
      handle_client_exit(code, signal, client_id)
    end,

    -- 处理器初始化（默认为空，由 setup 填充）
    handlers = {},

    -- 注意：settings 和 init_options 由各个 backend 策略提供
    -- 不在这里设置默认值，避免不同 backend 之间的配置冲突
  }
end

local function build_native_registered_config()
  local cfg = vim.deepcopy(M.get_default_config())
  cfg.on_attach = M.on_attach
  cfg.capabilities = capabilities
  cfg.handlers = M.handlers
  cfg.reuse_client = should_reuse_client
  cfg.root_dir = function(bufnr, on_dir)
    if not is_supported_buffer(bufnr) or not is_buf_ready_for_native(bufnr) then
      return
    end

    local ok_runtime, runtime = pcall(build_runtime_for_buf, bufnr, M.get_default_config())
    if not ok_runtime then
      clear_buf_ready(bufnr)
      return
    end

    refresh_native_registered_config(runtime)
    on_dir(runtime.root_dir)
  end

  return cfg
end

local function register_native_config()
  if not native_mode or native_config_registered then
    return
  end

  vim.lsp.config(NATIVE_CONFIG_NAME, build_native_registered_config())
  native_config_registered = true
end

local function enable_native_config()
  if not native_mode or native_config_enabled then
    return
  end

  local already_enabled = type(vim.lsp.is_enabled) == "function" and vim.lsp.is_enabled(NATIVE_CONFIG_NAME)
  if not already_enabled then
    vim.lsp.enable(NATIVE_CONFIG_NAME)
  end
  native_config_enabled = true
end

function M.cleanup()
  remote_root_cache = {}
  pending_root_probes = {}
  runtime_cache = {}
  root_correction_once = {}
  native_ready_buffers = {}
  stopping_clients = {}
  last_registered_runtime = nil
  cache_tick = 0
end

-----------------------------------------------------------------------
-- M.setup(capabilities_override)
-- 功能：初始化 LSP 模块
-- 参数：capabilities_override - 可选的能力覆盖
function M.setup(capabilities_override)
  if initialized then
    return
  end

  -- 初始化客户端能力
  capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.workspace = capabilities.workspace or {}
  capabilities.workspace.didChangeWatchedFiles = { dynamicRegistration = false }

  -- 添加 workspace diagnostic capability（ty LSP 0.0.8 需要）
  capabilities.workspace.diagnostic = {
    dynamicRegistration = false,
    relatedDocumentSupport = false,
  }

  -- 启用 pull diagnostics（ty LSP 0.0.8 通过 pull model 正确返回语法错误诊断）
  -- 实测证明 ty 的 pull diagnostics 实现完全正常，必须启用才能显示诊断
  capabilities.textDocument.diagnostic = {
    dynamicRegistration = false,
    relatedDocumentSupport = false,
  }

  -- 应用能力覆盖
  if capabilities_override then
    capabilities = vim.tbl_deep_extend("force", capabilities, capabilities_override)
  end

  native_mode = is_native_lsp_available()

  -- 注册文件类型自动命令
  vim.api.nvim_create_autocmd("FileType", {
    pattern = SUPPORTED_FILETYPES,
    callback = function(args)
      M.enable_pyright_remote(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    callback = function(args)
      clear_buf_ready(args.buf)
    end,
  })

  -- 配置默认处理器
  -- 统一使用 diagnostics 模块的处理器，避免与 init.lua 重复逻辑
  M.handlers = diagnostics.get_handlers(M.jump_with_oil)

  if native_mode then
    register_native_config()
    enable_native_config()
  end

  initialized = true

  -- 为已存在的缓冲区启动客户端
  vim.schedule(M.kick_existing_python)
end

-----------------------------------------------------------------------
-- 跳转处理函数
-----------------------------------------------------------------------
M.jump_with_oil = function(err, result, ctx, _)
  if err then
    vim.notify(string.format("[pyright_remote] jump error: %s", err.message or err), vim.log.levels.ERROR)
    return
  end
  if not result or (vim.islist(result) and #result == 0) then
    vim.notify("[pyright_remote] no locations", vim.log.levels.WARN)
    return
  end

  local client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id)
  local enc = client and client.offset_encoding or "utf-16"

  local cur_name = vim.api.nvim_buf_get_name(0)
  local cur_host = get_oil_ssh_host_from_bufname(cur_name)
  if cur_host and cur_host ~= "" then
    config.set({ host = cur_host })
  end

  local function normalize(loc)
    if not loc then
      return
    end
    local uri = loc.uri or loc.targetUri
    if not uri then
      return
    end
    local fname = vim.uri_to_fname(uri)
    local oil_uri = path.to_oil_path(fname, config.get("host"))
    return {
      uri = oil_uri,
      range = loc.range or loc.targetSelectionRange or loc.targetRange,
    }
  end

  local locs = {}
  if result.uri or result.targetUri then
    local n = normalize(result)
    if n then
      table.insert(locs, n)
    end
  elseif vim.islist(result) then
    for _, loc in ipairs(result) do
      local n = normalize(loc)
      if n then
        table.insert(locs, n)
      end
    end
  end

  if #locs == 0 then
    vim.notify("[pyright_remote] locations missing URI", vim.log.levels.WARN)
    return
  end

  -- 跳转到第一个位置
  local function goto_loc(loc)
    local fname = vim.uri_to_fname(loc.uri)
    if not fname or fname == "" then
      return
    end
    local bufnr
    local win = vim.api.nvim_get_current_win()

    -- 复用现有缓冲区避免重新加载
    if fname == vim.api.nvim_buf_get_name(0) then
      bufnr = vim.api.nvim_get_current_buf()
    else
      local existing = vim.fn.bufnr(fname, false)
      if existing > 0 and vim.api.nvim_buf_is_loaded(existing) then
        bufnr = existing
      else
        bufnr = vim.fn.bufadd(fname)
        vim.fn.bufload(bufnr)
      end
      vim.api.nvim_set_current_buf(bufnr)
    end

    local pos = loc.range and loc.range.start or { line = 0, character = 0 }
    local line = (pos.line or 0) + 1
    local col_fallback = pos.character or 0

    local function place()
      local ok = false
      if vim.lsp.util._get_line_byte_from_position then
        local byte_col = vim.lsp.util._get_line_byte_from_position(bufnr, pos, enc)
        ok = pcall(vim.api.nvim_win_set_cursor, win, { line, byte_col })
      end
      if not ok then
        pcall(vim.api.nvim_win_set_cursor, win, { line, math.max(0, col_fallback) })
      end
      pcall(vim.cmd, "normal! zv")
      return ok
    end

    local placed = place()
    if not placed then
      vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
        buffer = bufnr,
        once = true,
        callback = function()
          place()
        end,
      })
      vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          place()
        end
      end, 120)
    end
  end

  goto_loc(locs[1])

  -- 如果有多个位置，显示 quickfix 列表
  if #locs > 1 then
    local items = {}
    for _, loc in ipairs(locs) do
      local pos = loc.range and loc.range.start or { line = 0, character = 0 }
      table.insert(items, {
        filename = vim.uri_to_fname(loc.uri),
        lnum = (pos.line or 0) + 1,
        col = (pos.character or 0) + 1,
      })
    end
    vim.fn.setqflist(items, "r")
    vim.cmd("copen")
  end
end

-----------------------------------------------------------------------
-- M.get_default_handlers()
-- 功能：获取默认的 LSP 处理器
-- 返回：处理器表
function M.get_default_handlers()
  return {
    ["textDocument/publishDiagnostics"] = function(err, params, ctx, cfg)
      if params and params.uri then
        local fname = vim.uri_to_fname(params.uri)
        params.uri = path.to_oil_path(fname, config.get("host"))
        if params.diagnostics then
          for _, d in ipairs(params.diagnostics) do
            if d.relatedInformation then
              for _, info in ipairs(d.relatedInformation) do
                local ri_uri = info.location and info.location.uri
                if ri_uri then
                  local rf = vim.uri_to_fname(ri_uri)
                  info.location.uri = path.to_oil_path(rf, config.get("host"))
                end
              end
            end
          end
        end
      end
      return vim.lsp.handlers["textDocument/publishDiagnostics"](err, params, ctx, cfg)
    end,
    ["textDocument/definition"] = M.jump_with_oil,
    ["textDocument/typeDefinition"] = M.jump_with_oil,
    ["textDocument/declaration"] = M.jump_with_oil,
    ["textDocument/implementation"] = M.jump_with_oil,
    ["textDocument/references"] = function(err, result, ctx, _)
      if err then
        vim.notify(string.format("[pyright_remote] references error: %s", err.message or err), vim.log.levels.ERROR)
        return
      end
      if not result or #result == 0 then
        vim.notify("[pyright_remote] no references", vim.log.levels.WARN)
        return
      end
      local items = {}
      for _, loc in ipairs(result) do
        local item = path.location_to_oil_item(loc, config.get("host"))
        if item then
          table.insert(items, item)
        end
      end
      if #items == 0 then
        vim.notify("[pyright_remote] references missing URI", vim.log.levels.WARN)
        return
      end
      vim.fn.setqflist(items, "r")
      vim.cmd("copen")
    end,
  }
end

-- 处理器存储（由 setup 初始化）
M.handlers = {}

-- 仅供测试使用的兼容层导出，不属于稳定公开 API。
M._compat = {
  build_root_cache_key = build_root_cache_key,
  build_runtime_cache_key = build_runtime_cache_key,
  build_runtime_for_buf = build_runtime_for_buf,
  build_client_config_from_runtime = build_client_config_from_runtime,
  build_native_client_config = build_native_client_config,
  get_root_resolution_for_buf = get_root_resolution_for_buf,
  request_remote_root_probe = request_remote_root_probe,
  ensure_root_resolution_for_runtime = ensure_root_resolution_for_runtime,
  hover_handler = hover_handler,
  apply_hover_window_style = apply_hover_window_style,
  handle_client_exit = handle_client_exit,
  is_native_mode = function()
    return native_mode
  end,
  is_buf_ready_for_native = is_buf_ready_for_native,
  mark_buf_ready = mark_buf_ready,
  clear_buf_ready = clear_buf_ready,
  refresh_native_registered_config = refresh_native_registered_config,
  register_native_config = register_native_config,
  enable_native_config = enable_native_config,
  stop_lsp_client = stop_lsp_client,
  should_reuse_client = should_reuse_client,
  cleanup = M.cleanup,
}

return M
