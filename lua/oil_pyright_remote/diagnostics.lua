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

-- 已知的“pyright_remote 诊断命名空间”集合（key=ns, value=true）
-- 用途：当用户执行 :DiagVirtualTextOn/Off 等命令时，我们可以仅更新本插件相关的命名空间配置，
-- 避免误改其他 LSP/文件类型的诊断显示。
local diagnostic_namespaces = {}

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
local function get_client_diagnostic_namespace(client)
  if not client or not client.id then
    return nil
  end

  -- 兼容不同版本：该函数在 0.8+ 通常可用
  if vim.lsp and vim.lsp.diagnostic and vim.lsp.diagnostic.get_namespace then
    return vim.lsp.diagnostic.get_namespace(client.id)
  end

  return nil
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

  -- 新签名：enable(bufnr, namespace)
  if pcall(vim.diagnostic.enable, bufnr, namespace) then
    return
  end

  -- 旧签名：enable(bufnr, { namespace = namespace })
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

  -- 只在“本 client 的诊断命名空间”上配置，避免污染全局诊断显示
  local ns = get_client_diagnostic_namespace(client)
  if ns then
    diagnostic_namespaces[ns] = true
  end

  -- 如果 setup 尚未执行（理论上不应发生），兜底用默认配置
  diagnostic_config = diagnostic_config or build_diagnostic_config(nil)

  -- 重要：第二个参数传 ns，表示“只对该 namespace 生效”
  -- 若 ns 为 nil，会退化为全局配置（不推荐），但为了不让诊断完全消失，这里仍做兜底。
  pcall(vim.diagnostic.config, diagnostic_config, ns)

  -- 启用诊断（尽量只启用本 namespace）
  enable_diagnostics(bufnr, ns)
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

      local fname = vim.uri_to_fname(params.uri)

      -- 使用 pcall 包裹转换，避免 host 缺失或路径异常直接抛错导致诊断处理链中断
      local ok, oil_uri = pcall(path.to_oil_path, fname, host)
      if ok then
        params.uri = oil_uri
      else
        -- 保留原始 URI，发出警告但不影响后续诊断显示
        vim.notify(
          string.format("[diagnostics] URI 转换失败，保持原值: %s -> %s", fname, tostring(oil_uri)),
          vim.log.levels.WARN
        )
      end

      -- 处理相关信息的 URI 转换
      if params.diagnostics then
        for _, d in ipairs(params.diagnostics) do
          if d.relatedInformation then
            for _, info in ipairs(d.relatedInformation) do
              local ri_uri = info.location and info.location.uri
              if ri_uri then
                local rf = vim.uri_to_fname(ri_uri)
                local ok2, oil_ri_uri = pcall(path.to_oil_path, rf, host)
                if ok2 then
                  info.location.uri = oil_ri_uri
                else
                  vim.notify(
                    string.format("[diagnostics] 关联 URI 转换失败，保持原值: %s -> %s", rf, tostring(oil_ri_uri)),
                    vim.log.levels.WARN
                  )
                end
              end
            end
          end
        end
      end
    end

    -- 调用原始处理器
    return vim.lsp.handlers["textDocument/publishDiagnostics"](err, params, ctx, cfg)
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
