-- diagnostics.lua: 诊断处理模块
-- 功能：管理 LSP 诊断显示、虚拟文本、URI 转换等
-- 设计原则：统一的诊断配置、清晰的 URI 处理流程

local M = {}

-- 依赖模块
local config = require("oil_pyright_remote.config")
local path = require("oil_pyright_remote.path")

-- 模块状态
local initialized = false
local handlers = {}
local diagnostic_config = nil

-- 已知的"pyright_remote 诊断命名空间"集合（key=ns, value=true）
-- 用途：当用户执行 :DiagVirtualTextOn/Off 等命令时，我们可以仅更新本插件相关的命名空间配置，
-- 避免误改其他 LSP/文件类型的诊断显示。
local diagnostic_namespaces = {}

-- 记录 client_id -> { [ns] = true, ... }，便于退出时清理（同时支持 push + pull）
local diagnostic_ns_by_client = {}

-----------------------------------------------------------------------
-- build_diagnostic_config(user_cfg)
-- 功能：构建本插件的诊断显示配置（默认值 + 用户覆盖）
-- 说明：
--   - 这里不直接调用 vim.diagnostic.config，因为那样会影响全局
--   - 真正应用配置由 apply_on_attach 在“客户端诊断命名空间”上完成
-----------------------------------------------------------------------
local function build_diagnostic_config(user_cfg)
  local base = {
    virtual_text = { prefix = "●", spacing = 2 },
    signs = true,
    underline = true,
    update_in_insert = true, -- 插入模式同样显示并更新诊断，方便即时反馈
    severity_sort = true,
  }

  if type(user_cfg) == "table" then
    return vim.tbl_deep_extend("force", base, user_cfg)
  end
  return base
end

-----------------------------------------------------------------------
-- get_client_diagnostic_namespace(client)
-- 功能：获取某个 LSP client 的诊断命名空间（namespace）
-- 说明：
--   Neovim 会为每个 LSP client 分配独立的诊断 namespace。
--   只有在该 namespace 上配置 vim.diagnostic.config，才能做到“只影响本 client 的诊断显示”。
-----------------------------------------------------------------------
local function get_client_diagnostic_namespace(client, is_pull)
  if not client or not client.id then
    return nil
  end

  -- 兼容不同版本：该函数在 0.8+ 通常可用
  if vim.lsp and vim.lsp.diagnostic and vim.lsp.diagnostic.get_namespace then
    -- 0.11+ 支持 is_pull 参数；旧版本会忽略额外参数，不影响兼容性
    local ok, ns = pcall(vim.lsp.diagnostic.get_namespace, client.id, is_pull)
    if ok then
      return ns
    end
    -- 兜底：尝试旧签名（仅 push）
    local ok2, ns2 = pcall(vim.lsp.diagnostic.get_namespace, client.id)
    if ok2 then
      return ns2
    end
  end

  return nil
end

-----------------------------------------------------------------------
-- collect_client_namespaces(client)
-- 功能：收集某个客户端的诊断命名空间（push + pull），去重后返回列表
-- 说明：
--   - Neovim 0.11 引入 pull diagnostics，会使用独立命名空间
--   - 若只配置 push namespace，pull 诊断会“存在但不显示”
-----------------------------------------------------------------------
local function collect_client_namespaces(client)
  local namespaces = {}
  local seen = {}

  -- push namespace（传统 publishDiagnostics）
  local push_ns = get_client_diagnostic_namespace(client, false)
  if push_ns and not seen[push_ns] then
    table.insert(namespaces, push_ns)
    seen[push_ns] = true
  end

  -- pull namespace（textDocument/diagnostic）
  local pull_ns = get_client_diagnostic_namespace(client, true)
  if pull_ns and not seen[pull_ns] then
    table.insert(namespaces, pull_ns)
    seen[pull_ns] = true
  end

  return namespaces
end

-----------------------------------------------------------------------
-- register_client_namespaces(client, namespaces)
-- 功能：登记客户端命名空间，供后续 toggle/cleanup 使用
-----------------------------------------------------------------------
local function register_client_namespaces(client, namespaces)
  if not client or not client.id then
    return
  end
  if type(namespaces) ~= "table" or #namespaces == 0 then
    return
  end

  local store = diagnostic_ns_by_client[client.id]
  if not store then
    store = {}
    diagnostic_ns_by_client[client.id] = store
  end

  for _, ns in ipairs(namespaces) do
    diagnostic_namespaces[ns] = true
    store[ns] = true
  end
end

-----------------------------------------------------------------------
-- to_oil_uri_safe(uri, host)
-- 功能：将 file:// URI 转成 oil-ssh:// URI（安全版）
-- 说明：
--   - 若已是 oil-ssh 或非 file:// URI，直接返回原值
--   - 若 host 缺失，则不做转换，避免抛错
--   - 该函数绝不抛异常，适合在诊断处理链路中使用
-----------------------------------------------------------------------
local function to_oil_uri_safe(uri, host)
  if type(uri) ~= "string" or uri == "" then
    return uri
  end
  -- 已是 oil-ssh://，直接返回
  if uri:match("^oil%-ssh://") then
    return uri
  end
  -- 仅处理 file:// URI，其他 scheme 保持原样
  if not uri:match("^file:") then
    return uri
  end
  if type(host) ~= "string" or host == "" then
    return uri
  end

  local fname = vim.uri_to_fname(uri)
  local ok, oil_uri = pcall(path.to_oil_path, fname, host)
  if ok then
    return oil_uri
  end

  -- 失败则保持原值，避免中断诊断处理
  return uri
end

-----------------------------------------------------------------------
-- rewrite_related_information_uris(diagnostics, host)
-- 功能：批量修正 diagnostics[].relatedInformation[].location.uri
-- 说明：
--   - pull/push 模式都可能带 relatedInformation
--   - 若不转换，点击跳转会指向本地 file:// 路径
-----------------------------------------------------------------------
local function rewrite_related_information_uris(diagnostics, host)
  if type(diagnostics) ~= "table" then
    return
  end
  for _, d in ipairs(diagnostics) do
    local rel = d.relatedInformation
    if rel then
      for _, info in ipairs(rel) do
        local loc = info.location
        if loc and loc.uri then
          local new_uri = to_oil_uri_safe(loc.uri, host)
          if new_uri and new_uri ~= loc.uri then
            loc.uri = new_uri
          end
        end
      end
    end
  end
end

-----------------------------------------------------------------------
-- enable_diagnostics(bufnr, namespace)
-- 功能：兼容性封装：仅启用指定 namespace 的诊断
-- 说明：
--   不同 Neovim 版本对 vim.diagnostic.enable 的参数签名略有差异。
--   我们按“新 -> 旧”的顺序尝试，保证尽量不报错。
-----------------------------------------------------------------------
local function enable_diagnostics(bufnr, namespace)
  if not namespace then
    pcall(vim.diagnostic.enable, bufnr)
    return
  end

  -- 最新签名 (Neovim 0.10+)：enable(true, {bufnr=..., ns_id=...})
  if pcall(vim.diagnostic.enable, true, { bufnr = bufnr, ns_id = namespace }) then
    return
  end

  -- 备选签名 (Neovim 0.10+)：enable({bufnr=..., ns_id=...})
  if pcall(vim.diagnostic.enable, { bufnr = bufnr, ns_id = namespace }) then
    return
  end

  -- 已废弃签名 (Neovim < 0.10，产生警告)：enable(bufnr, namespace)
  if pcall(vim.diagnostic.enable, bufnr, namespace) then
    return
  end

  -- 最旧签名：enable(bufnr, { namespace = namespace })
  pcall(vim.diagnostic.enable, bufnr, { namespace = namespace })
end

-----------------------------------------------------------------------
-- M.apply_on_attach(client, bufnr)
-- 功能：在 LSP 客户端附着时应用诊断配置
-- 参数：
--   client - LSP 客户端对象
--   bufnr  - 缓冲区编号
function M.apply_on_attach(client, bufnr)
  if client.name ~= "pyright_remote" then
    return
  end

  -- 只在"本 client 的诊断命名空间"上配置，避免污染全局诊断显示
  -- 注意：Neovim 0.11 同时存在 push + pull 两套命名空间
  local namespaces = collect_client_namespaces(client)
  register_client_namespaces(client, namespaces)

  -- 如果 setup 尚未执行（理论上不应发生），兜底用默认配置
  diagnostic_config = diagnostic_config or build_diagnostic_config(nil)

  -- 重要：第二个参数传 ns，表示“只对该 namespace 生效”
  -- 若 ns 不存在（极少数旧版本），退化为全局配置，保证诊断不消失
  if #namespaces == 0 then
    pcall(vim.diagnostic.config, diagnostic_config)
    enable_diagnostics(bufnr, nil)
    return
  end

  for _, ns in ipairs(namespaces) do
    pcall(vim.diagnostic.config, diagnostic_config, ns)
    -- 启用诊断（尽量只启用本 namespace）
    enable_diagnostics(bufnr, ns)
  end
end

-----------------------------------------------------------------------
-- M.toggle_virtual_text(enabled)
-- 功能：切换虚拟文本显示
-- 参数：enabled - 布尔值，nil 表示切换状态
function M.toggle_virtual_text(enabled)
  -- 这里的目标是“只影响 pyright_remote 的诊断”，因此我们只更新已记录的 namespace。
  -- 如果当前还没有任何 namespace（比如尚未 attach），就仅更新内存配置，等 attach 时生效。

  diagnostic_config = diagnostic_config or build_diagnostic_config(nil)

  if enabled == nil then
    -- 切换状态：优先读取当前内存配置
    enabled = not diagnostic_config.virtual_text
  end

  if enabled then
    diagnostic_config.virtual_text = { prefix = "●", spacing = 2 }
    diagnostic_config.signs = true
    vim.notify("[diagnostic] virtual text ON", vim.log.levels.INFO)
  else
    diagnostic_config.virtual_text = false
    vim.notify("[diagnostic] virtual text OFF", vim.log.levels.INFO)
  end

  -- 将更新后的配置应用到所有已知 namespace（只影响本插件的诊断）
  for ns, _ in pairs(diagnostic_namespaces) do
    pcall(vim.diagnostic.config, diagnostic_config, ns)
  end
end

-----------------------------------------------------------------------
-- M.create_toggle_commands()
-- 功能：创建诊断切换命令
function M.create_toggle_commands()
  vim.api.nvim_create_user_command("DiagVirtualTextOn", function()
    M.toggle_virtual_text(true)
  end, { nargs = 0 })

  vim.api.nvim_create_user_command("DiagVirtualTextOff", function()
    M.toggle_virtual_text(false)
  end, { nargs = 0 })

  vim.api.nvim_create_user_command("DiagVirtualTextToggle", function()
    M.toggle_virtual_text()
  end, { nargs = 0 })
end

-----------------------------------------------------------------------
-- M.cleanup_client(client_id)
-- 功能：清理某个客户端对应的诊断 namespace
-- 说明：
--   - 断网/重连会创建新 client，旧 namespace 若不清理会积累诊断数据。
--   - 这里主动 reset，释放内存并避免重复诊断叠加。
-----------------------------------------------------------------------
function M.cleanup_client(client_id)
  if not client_id then
    return
  end
  local ns_set = diagnostic_ns_by_client[client_id]
  if not ns_set then
    return
  end
  diagnostic_ns_by_client[client_id] = nil

  -- 逐一清理 push/pull 命名空间
  for ns, _ in pairs(ns_set) do
    diagnostic_namespaces[ns] = nil
    pcall(vim.diagnostic.reset, ns)
  end
end

-----------------------------------------------------------------------
-- M.get_diagnostics(bufnr)
-- 功能：获取缓冲区的诊断信息
-- 参数：bufnr - 缓冲区编号，可选
-- 返回：诊断列表
function M.get_diagnostics(bufnr)
  bufnr = bufnr or 0
  return vim.diagnostic.get(bufnr)
end

-----------------------------------------------------------------------
-- M.set_diagnostics_signs(signs_config)
-- 功能：设置诊断符号
-- 参数：signs_config - 符号配置表
function M.set_diagnostics_signs(signs_config)
  signs_config = signs_config or { Error = "E", Warn = "W", Hint = "H", Info = "I" }
  for type, icon in pairs(signs_config) do
    local hl = "DiagnosticSign" .. type
    vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" })
  end
end

-----------------------------------------------------------------------
-- M.open_diagnostic_float()
-- 功能：打开当前行的诊断浮动窗口
function M.open_diagnostic_float()
  vim.diagnostic.open_float(nil, { scope = "line" })
end

-----------------------------------------------------------------------
-- M.goto_next_diagnostic()
-- 功能：跳转到下一个诊断
function M.goto_next_diagnostic()
  vim.diagnostic.goto_next()
end

-----------------------------------------------------------------------
-- M.goto_prev_diagnostic()
-- 功能：跳转到上一个诊断
function M.goto_prev_diagnostic()
  vim.diagnostic.goto_prev()
end

-----------------------------------------------------------------------
-- M.get_publish_diagnostics_handler()
-- 功能：获取 textDocument/publishDiagnostics 处理器
-- 返回：处理器函数
function M.get_publish_diagnostics_handler()
  return function(err, params, ctx, cfg)
    if params and params.uri then
      -- 优先读取当前客户端在 config 中存储的 host（客户端级别更可靠，避免依赖全局变量导致 host 为空）
      local client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id)
      local host = (client and client.config and client.config._pyright_remote_host) or config.get("host")

      -- 将 file:// URI 转成 oil-ssh://，保证诊断落在正确的缓冲区
      local new_uri = to_oil_uri_safe(params.uri, host)
      if new_uri and new_uri ~= params.uri then
        params.uri = new_uri
      end

      -- 处理相关信息的 URI 转换
      if params.diagnostics then
        rewrite_related_information_uris(params.diagnostics, host)
      end
    end

    -- 调用原始处理器
    return vim.lsp.handlers["textDocument/publishDiagnostics"](err, params, ctx, cfg)
  end
end

-----------------------------------------------------------------------
-- M.get_pull_diagnostics_handler()
-- 功能：获取 textDocument/diagnostic 处理器（pull diagnostics）
-- 关键点：
--   - Neovim 0.11 使用 pull 诊断时，会根据 ctx.params.textDocument.uri 定位缓冲区
--   - 我们发送给服务器的是 file:// URI（远程真实路径），但本地缓冲区是 oil-ssh://
--   - 若不转换，诊断会写到“本地 file:// 缓冲区”，导致实际 buffer 没有诊断显示
-----------------------------------------------------------------------
function M.get_pull_diagnostics_handler()
  return function(err, result, ctx, cfg)
    -- 选择默认处理器：优先 handler 表，其次兜底到 vim.lsp.diagnostic
    local handler = vim.lsp.handlers and vim.lsp.handlers["textDocument/diagnostic"]
    if not handler and vim.lsp and vim.lsp.diagnostic and vim.lsp.diagnostic.on_diagnostic then
      handler = vim.lsp.diagnostic.on_diagnostic
    end
    if not handler then
      return
    end

    -- 尝试获取 host，用于 URI 转换
    local client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id)
    local host = (client and client.config and client.config._pyright_remote_host) or config.get("host")

    -- 默认复用原 ctx；只有在需要修改 URI 时才复制，避免无意义的深拷贝
    local new_ctx = ctx

    -- 修正 pull 诊断的目标 URI，让诊断落在 oil-ssh 缓冲区
    if ctx and ctx.params and ctx.params.textDocument and ctx.params.textDocument.uri then
      local old_uri = ctx.params.textDocument.uri
      local new_uri = to_oil_uri_safe(old_uri, host)
      if new_uri and new_uri ~= old_uri then
        -- 深拷贝 params，避免修改原始 ctx 引发副作用
        new_ctx = vim.tbl_deep_extend("force", {}, ctx)
        new_ctx.params = vim.deepcopy(ctx.params)
        new_ctx.params.textDocument = vim.tbl_deep_extend("force", {}, ctx.params.textDocument)
        new_ctx.params.textDocument.uri = new_uri
      end
    end

    -- 修正 relatedInformation 的 URI，确保跳转也走 oil-ssh
    if result and result.items then
      rewrite_related_information_uris(result.items, host)
    end

    -- 交给 Neovim 默认处理器完成诊断写入
    return handler(err, result, new_ctx, cfg)
  end
end

-----------------------------------------------------------------------
-- M.get_location_handler()
-- 功能：获取位置跳转处理器
-- 参数：jump_func - 跳转函数（如 lsp.jump_with_oil）
-- 返回：处理器函数
function M.get_location_handler(jump_func)
  return function(err, result, ctx, _)
    if err then
      vim.notify(string.format("[diagnostics] location error: %s", err.message or err), vim.log.levels.ERROR)
      return
    end

    if not result or (vim.islist(result) and #result == 0) then
      vim.notify("[diagnostics] no locations", vim.log.levels.WARN)
      return
    end

    -- 使用提供的跳转函数
    if jump_func and type(jump_func) == "function" then
      jump_func(err, result, ctx, _)
    else
      -- 默认处理：转换为 quickfix
      local items = {}
      local locations = vim.islist(result) and result or { result }

      for _, loc in ipairs(locations) do
        local item = path.location_to_oil_item(loc, config.get("host"))
        if item then
          table.insert(items, item)
        end
      end

      if #items > 0 then
        vim.fn.setqflist(items, "r")
        vim.cmd("copen")
      end
    end
  end
end

-----------------------------------------------------------------------
-- M.get_references_handler()
-- 功能：获取引用查找处理器
-- 返回：处理器函数
function M.get_references_handler()
  return function(err, result, ctx, _)
    if err then
      vim.notify(string.format("[diagnostics] references error: %s", err.message or err), vim.log.levels.ERROR)
      return
    end

    if not result or #result == 0 then
      vim.notify("[diagnostics] no references", vim.log.levels.WARN)
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
      vim.notify("[diagnostics] references missing URI", vim.log.levels.WARN)
      return
    end

    vim.fn.setqflist(items, "r")
    vim.cmd("copen")
  end
end

-----------------------------------------------------------------------
-- M.get_handlers(jump_func)
-- 功能：获取所有诊断相关的处理器
-- 参数：jump_func - 跳转函数
-- 返回：处理器表
function M.get_handlers(jump_func)
  return {
    ["textDocument/publishDiagnostics"] = M.get_publish_diagnostics_handler(),
    ["textDocument/diagnostic"] = M.get_pull_diagnostics_handler(),
    ["textDocument/definition"] = M.get_location_handler(jump_func),
    ["textDocument/typeDefinition"] = M.get_location_handler(jump_func),
    ["textDocument/declaration"] = M.get_location_handler(jump_func),
    ["textDocument/implementation"] = M.get_location_handler(jump_func),
    ["textDocument/references"] = M.get_references_handler(),
  }
end

-----------------------------------------------------------------------
-- M.setup(opts)
-- 功能：初始化诊断模块
-- 参数：opts - 配置选项：
--          signs: 符号配置
--          commands: 是否创建切换命令
--          keymaps: 是否设置按键映射
--          jump_func: 跳转函数
function M.setup(opts)
  opts = opts or {}

  if initialized then
    return
  end

  -- 保存诊断显示配置（默认 + 用户覆盖）
  diagnostic_config = build_diagnostic_config(opts.diagnostic)

  -- 设置诊断符号
  if opts.signs then
    M.set_diagnostics_signs(opts.signs)
  end

  -- 创建切换命令
  if opts.commands ~= false then
    M.create_toggle_commands()
  end

  -- 按键映射：建议由 LSP on_attach 做 buffer-local 绑定，避免影响非远程缓冲区。
  -- 这里保留 opts.keymaps 参数用于向后兼容，但默认不再设置全局 keymap。
  -- 若你确实需要全局 keymap，可在自己的配置中自行设置：
  --   vim.keymap.set("n", "<leader>e", vim.diagnostic.open_float, { desc = "Line diagnostics" })
  --   vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Previous diagnostic" })
  --   vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Next diagnostic" })

  -- 预生成处理器
  handlers = M.get_handlers(opts.jump_func)

  initialized = true
end

-----------------------------------------------------------------------
-- M.get_handler(name)
-- 功能：获取指定名称的处理器
-- 参数：name - 处理器名称
-- 返回：处理器函数
function M.get_handler(name)
  return handlers[name]
end

return M
