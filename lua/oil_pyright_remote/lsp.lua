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

-- 支持的文件类型白名单（严格控制，避免错误附着）
local SUPPORTED_FILETYPES = { "python" }

-- 在远程主机上寻找项目根：逐级向上检测 root_markers
local function find_remote_root(remote_path, markers)
  -- 安全校验：缺主机或路径直接放弃
  if not remote_path or remote_path == "" then
    return nil
  end
  local host = config.get("host")
  if not host or host == "" then
    return nil
  end

  markers = markers or (M.get_default_config().root_markers or {})
  if #markers == 0 then
    return nil
  end

  -- Shell 安全转义，防止路径中包含空格或单引号
  local function esc(str)
    return (str or ""):gsub("'", "'\\''")
  end

  local quoted_markers = {}
  for _, m in ipairs(markers) do
    table.insert(quoted_markers, string.format([["%s"]], m))
  end

  -- 使用 ssh 在远程侧逐级检查标记文件，找到则回显根路径
  local script = string.format([[
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

  local stdout = {}
  local job = vim.fn.jobstart(ssh_runner.remote_bash(script), {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stdout, line)
        end
      end
    end,
  })

  if job <= 0 then
    return nil
  end

  -- 最长等待 8s，失败则返回 nil 交给后续回退
  local waited = vim.fn.jobwait({ job }, 8000)[1]
  if waited ~= 0 or #stdout == 0 then
    return nil
  end
  return stdout[1]
end

-----------------------------------------------------------------------
-- 辅助函数：检查缓冲区是否为支持的文件类型
-----------------------------------------------------------------------
local function is_supported_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  return vim.tbl_contains(SUPPORTED_FILETYPES, ft)
end

-----------------------------------------------------------------------
-- 辅助函数：获取 LSP 客户端（兼容不同 Neovim 版本）
-----------------------------------------------------------------------
local function get_lsp_clients(opts)
  if vim.lsp.get_clients then
    return vim.lsp.get_clients(opts)
  end

  local clients = {}
  if not vim.lsp.get_active_clients then
    return clients
  end

  for _, c in ipairs(vim.lsp.get_active_clients()) do
    local ok_name = (not opts or not opts.name) or (c.name == opts.name)
    local ok_buf = (not opts or not opts.bufnr) or vim.lsp.buf_is_attached(opts.bufnr, c.id)
    if ok_name and ok_buf then
      table.insert(clients, c)
    end
  end
  return clients
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
  bufmap("n", "K", vim.lsp.buf.hover, "Hover")
  bufmap("n", "gr", vim.lsp.buf.references, "References")
  bufmap("n", "<leader>rn", vim.lsp.buf.rename, "Rename")
  bufmap("n", "<leader>ac", vim.lsp.buf.code_action, "Code action")

  -- pyright_remote 特殊处理
  if client.name == "pyright_remote" then
    -- 禁用格式化（通常由其他插件处理）
    client.server_capabilities.documentFormattingProvider = false

    -- 配置诊断显示
    pcall(vim.diagnostic.config, {
      virtual_text = { prefix = "●", spacing = 2 },
      signs = true,
      underline = true,
      update_in_insert = false,
      severity_sort = true,
    })
    pcall(vim.diagnostic.enable, bufnr)

    -- 自定义跳转处理器，确保使用 oil 路径
    local function req(method)
      return function()
        local name = vim.api.nvim_buf_get_name(bufnr)
        local h = name:match("^oil%-ssh://([^/]+)//")
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

    -- 通知用户客户端已附着
    vim.notify(
      string.format(
        "[pyright_remote] attached. root: %s",
        client.config.root_dir
          or (client.config.workspace_folders or {})[1] and (client.config.workspace_folders or {})[1].name
          or "?"
      ),
      vim.log.levels.INFO
    )
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
  if not is_supported_buffer(bufnr) then
    error("build_config: unsupported filetype for buffer " .. bufnr)
  end

  local cfg = vim.deepcopy(M.get_default_config())

  -- 获取缓冲区路径并计算工作区根目录
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local remote_path = path.from_oil_path(bufname) or vim.fn.fnamemodify(bufname, ":p")

  -- 远程根目录：优先用户配置，其次远程检测，最后退回文件所在目录
  local root_dir = config.get("root")
  if not root_dir or root_dir == "" then
    local markers = cfg.root_markers or M.get_default_config().root_markers
    local base = vim.fn.fnamemodify(remote_path, ":p:h")
    -- 在远程侧检查 root_markers；失败则直接用当前目录
    root_dir = find_remote_root(base, markers) or base
  end

  cfg.root_dir = root_dir
  cfg.workspace_folders = {
    {
      uri = vim.uri_from_fname(root_dir),
      name = root_dir,
    },
  }

  -- 合并运行时配置
  cfg = vim.tbl_deep_extend("force", {}, cfg, {
    name = "pyright_remote",
    on_attach = M.on_attach,
    capabilities = capabilities,
    bufnr = bufnr,
    handlers = M.handlers,                  -- 注入自定义处理器，确保诊断 URI 转换生效
    _pyright_remote_host = config.get("host"), -- 将主机信息写入客户端配置，处理器可读取，避免 host 为空导致诊断丢失
    settings = {
      python = {
        analysis = {
          typeCheckingMode = "basic",
          autoSearchPaths = true,
          useLibraryCodeForTypes = true,
          autoImportCompletions = true,
        },
        pythonPath = config.get("env") .. "/bin/python",
      },
    },
  })

  -- 构建启动命令
  cfg.cmd = ssh_runner.build_pyright_cmd()

  return cfg
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

  -- 检查是否已有客户端
  local existing = M.get_clients({ bufnr = bufnr, name = "pyright_remote" })
  if existing and #existing > 0 then
    return
  end

  -- 从缓冲区名称提取主机信息
  local name = vim.api.nvim_buf_get_name(bufnr)
  local h = name:match("^oil%-ssh://([^/]+)//")
  if h and h ~= "" then
    config.set({ host = h })
  end

  local function start_client()
    local cfg = M.build_config(bufnr)

    -- 启动通知
    if config.get("start_notify") then
      vim.schedule(function()
        pcall(
          vim.notify,
          string.format(
            "[pyright_remote] starting. root=%s file=%s",
            tostring(cfg.root_dir),
            vim.api.nvim_buf_get_name(bufnr)
          ),
          vim.log.levels.INFO
        )
      end)
    end

    local client_id = vim.lsp.start(cfg)
    if client_id then
      state.reset_reconnect_attempted()
    end
    return client_id
  end

  -- 确保环境配置正确
  installer.ensure_env_and_pyright_async(function(ok)
    if ok then
      start_client()
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
    state.increment_suppress_count()
    for _, c in ipairs(clients) do
      vim.lsp.stop_client(c.id)
    end
  end

  -- 启动新客户端
  M.enable_pyright_remote(bufnr)
end

-----------------------------------------------------------------------
-- M.get_default_config()
-- 功能：获取默认的 pyright_remote 配置
-- 返回：配置表
function M.get_default_config()
  return {
    name = "pyright_remote",

    -- 严格控制文件类型
    filetypes = SUPPORTED_FILETYPES,

    -- 工作区根标记
    root_markers = {
      "pyproject.toml",
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
      state.pyright_on_exit(code, signal, client_id)
    end,

    -- 处理器初始化（默认为空，由 setup 填充）
    handlers = {},

    -- 默认设置
    settings = {
      python = {
        analysis = {
          typeCheckingMode = "basic",
          autoSearchPaths = true,
          useLibraryCodeForTypes = true,
        },
      },
    },
  }
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

  -- 应用能力覆盖
  if capabilities_override then
    capabilities = vim.tbl_deep_extend("force", capabilities, capabilities_override)
  end

  -- 注册文件类型自动命令
  vim.api.nvim_create_autocmd("FileType", {
    pattern = SUPPORTED_FILETYPES,
    callback = function(args)
      M.enable_pyright_remote(args.buf)
    end,
  })

  -- 配置默认处理器
  -- 统一使用 diagnostics 模块的处理器，避免与 init.lua 重复逻辑
  M.handlers = diagnostics.get_handlers(M.jump_with_oil)

  -- 注册 LSP 配置（如果支持）
  if vim.lsp and vim.lsp.config then
    vim.lsp.config("pyright_remote", M.get_default_config())
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
  local cur_host = cur_name:match("^oil%-ssh://([^/]+)//")
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

return M
