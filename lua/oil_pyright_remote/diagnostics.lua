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

  -- 配置诊断显示
  pcall(vim.diagnostic.config, {
    virtual_text = { prefix = "●", spacing = 2 },
    signs = true,
    underline = true,
    update_in_insert = false,
    severity_sort = true,
  })

  -- 启用诊断
  pcall(vim.diagnostic.enable, bufnr)
end

-----------------------------------------------------------------------
-- M.toggle_virtual_text(enabled)
-- 功能：切换虚拟文本显示
-- 参数：enabled - 布尔值，nil 表示切换状态
function M.toggle_virtual_text(enabled)
  if enabled == nil then
    -- 切换状态
    local current = vim.diagnostic.config().virtual_text
    enabled = not current
  end

  if enabled then
    vim.diagnostic.config({
      virtual_text = { prefix = "●", spacing = 2 },
      signs = true,
    })
    vim.notify("[diagnostic] virtual text ON", vim.log.levels.INFO)
  else
    vim.diagnostic.config({ virtual_text = false })
    vim.notify("[diagnostic] virtual text OFF", vim.log.levels.INFO)
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
      local fname = vim.uri_to_fname(params.uri)
      -- 转换为 oil-ssh 路径
      params.uri = path.to_oil_path(fname, config.get("host"))

      -- 处理相关信息的 URI 转换
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

  -- 设置诊断符号
  if opts.signs then
    M.set_diagnostics_signs(opts.signs)
  end

  -- 创建切换命令
  if opts.commands ~= false then
    M.create_toggle_commands()
  end

  -- 设置按键映射
  if opts.keymaps ~= false then
    vim.keymap.set("n", "<leader>e", M.open_diagnostic_float, { desc = "Line diagnostics" })
    vim.keymap.set("n", "[d", M.goto_prev_diagnostic, { desc = "Previous diagnostic" })
    vim.keymap.set("n", "]d", M.goto_next_diagnostic, { desc = "Next diagnostic" })
  end

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