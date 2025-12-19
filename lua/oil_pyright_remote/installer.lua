-- installer.lua: 环境验证和 pyright 安装模块
-- 功能：处理远程环境检查、pyright 安装、用户交互等
-- 设计原则：清晰的流程控制、友好的用户提示、可靠的状态跟踪

local M = {}

-- 依赖模块
local config = require("oil_pyright_remote.config")
local state = require("oil_pyright_remote.state")
local ssh_runner = require("oil_pyright_remote.ssh_runner")

-----------------------------------------------------------------------
-- 全局浮动窗口状态（用于环境选择界面，防止浮窗遗留）
-----------------------------------------------------------------------
local floating_state = {
  win = nil,    -- 当前浮窗窗口 id
  buf = nil,    -- 当前浮窗 buffer id
  timer = nil,  -- 兜底超时计时器
  closed = true -- 是否已清理完成
}

-----------------------------------------------------------------------
-- 辅助函数：统一的日志输出
-----------------------------------------------------------------------
local function notify(msg, level, quiet)
  if quiet then
    return
  end
  vim.notify(msg, level or vim.log.levels.INFO)
end

-----------------------------------------------------------------------
-- M.prompt_env_path_async(cb, opts)
-- 功能：异步提示用户输入环境路径
-- 参数：
--   cb   - 回调函数 cb(python_path)
--   opts - 选项表：
--          prompt: 是否允许提示，默认true
-- 返回：无
function M.prompt_env_path_async(cb, opts)
  opts = opts or {}
  local allow_prompt = opts.prompt ~= false

  if not allow_prompt then
    cb(nil)
    return
  end

  local function ask_python()
    local current_env = config.get("env")
    local default_py = (current_env or "") .. "/bin/python"
    if default_py == "/bin/python" then
      default_py = ""
      config.set({ env = "" })
    end

    local input = vim.fn.input(string.format("Remote python path (leave empty to keep current): [%s] ", default_py))
    input = vim.fn.trim(input)
    if input ~= nil and input ~= "" then
      local env_dir = input:gsub("/bin/python$", ""):gsub("/?$", "")
      config.set({ env = env_dir })
      cb(env_dir .. "/bin/python")
      return
    end
    cb(default_py)
  end

  -- 检查是否允许自动提示
  local auto_prompt = config.get("auto_prompt")
  if not auto_prompt then
    cb(nil)
    return
  end

  -- 检查是否有配置的环境
  local current_env = config.get("env")
  if not current_env or current_env == "" then
    local host = config.get("host")
    local envs = state.list_envs(host)
    if #envs == 1 then
      -- 只有一个环境时自动使用，直接返回不阻塞UI
      config.set({ env = envs[1] })
      cb(envs[1] .. "/bin/python")
    elseif #envs > 1 then
      -- 多个环境时让用户选择，但由于prompted_env已置位，本session只会出现一次
      M.select_env_async(host, function(choice)
        if choice and choice ~= "" then
          config.set({ env = choice })
          cb(choice .. "/bin/python")
        else
          cb(nil)
        end
      end)
    else
      -- 没有历史记录，直接询问
      ask_python()
    end
  else
    -- 已有配置的环境，直接使用不阻塞UI
    cb(current_env .. "/bin/python")
  end
end

-----------------------------------------------------------------------
-- M.select_env_async(host, cb)
-- 功能：异步显示环境选择界面
-- 参数：
--   host - 主机名
--   cb   - 回调函数 cb(selected_env)
function M.select_env_async(host, cb)
  -- 先清理旧的浮窗，避免残留
  M.cleanup_floating_window()

  local envs = state.list_envs(host)
  if not envs or #envs == 0 then
    cb(nil)
    return
  end

  -- 首选原生 vim.ui.select，减少自绘浮窗残留几率
  if vim.ui.select then
    floating_state.closed = false
    floating_state.timer = vim.loop.new_timer()

    -- 兜底 15s 超时，超时自动收尾
    floating_state.timer:start(15000, 0, function()
      vim.schedule(function()
        if not floating_state.closed then
          floating_state.closed = true
          cb(nil)
        end
        if floating_state.timer then
          floating_state.timer:close()
          floating_state.timer = nil
        end
      end)
    end)

    vim.ui.select(envs, {
      prompt = "Select Python virtual environment:",
      format_item = function(item)
        return item
      end,
    }, function(choice)
      if floating_state.closed then
        return
      end
      floating_state.closed = true
      if floating_state.timer then
        floating_state.timer:close()
        floating_state.timer = nil
      end
      cb(choice)
    end)
    return
  end

  -- 自绘浮窗回退方案
  local maxlen = 0
  for _, v in ipairs(envs) do
    maxlen = math.max(maxlen, #v)
  end
  local width = math.min(math.max(maxlen + 4, 24), math.max(24, vim.o.columns - 4))
  local height = math.min(#envs, 10)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, envs)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })

  floating_state.win = win
  floating_state.buf = buf
  floating_state.closed = false

  local cursor = 1
  vim.api.nvim_win_set_cursor(win, { cursor, 0 })

  local function finish(choice)
    if floating_state.closed then
      return
    end
    floating_state.closed = true

    if floating_state.timer then
      floating_state.timer:close()
      floating_state.timer = nil
    end

    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end

    floating_state.win = nil
    floating_state.buf = nil

    cb(choice)
  end

  local function move(delta)
    cursor = math.max(1, math.min(cursor + delta, #envs))
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { cursor, 0 })
    end
  end

  -- 键位映射
  vim.keymap.set("n", "<CR>", function()
    finish(envs[cursor])
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    finish(nil)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "q", function()
    finish(nil)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "j", function()
    move(1)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "k", function()
    move(-1)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Down>", function()
    move(1)
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Up>", function()
    move(-1)
  end, { buffer = buf, nowait = true, silent = true })

  -- 更稳健的清理：离开、隐藏、窗口被外部关闭都立即收尾
  vim.api.nvim_create_autocmd({ "BufLeave", "BufHidden" }, {
    buffer = buf,
    once = true,
    callback = function()
      finish(nil)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      finish(nil)
    end,
  })

  -- 兜底超时（15s）防遗留
  floating_state.timer = vim.loop.new_timer()
  floating_state.timer:start(15000, 0, function()
    vim.schedule(function()
      finish(nil)
    end)
  end)
end

-----------------------------------------------------------------------
-- M.cleanup_floating_window()
-- 功能：显式清理当前浮窗（供退出或重新打开时调用）
-----------------------------------------------------------------------
function M.cleanup_floating_window()
  if floating_state.timer then
    floating_state.timer:close()
    floating_state.timer = nil
  end

  if floating_state.win and vim.api.nvim_win_is_valid(floating_state.win) then
    pcall(vim.api.nvim_win_close, floating_state.win, true)
  end

  if floating_state.buf and vim.api.nvim_buf_is_valid(floating_state.buf) then
    pcall(vim.api.nvim_buf_delete, floating_state.buf, { force = true })
  end

  floating_state.win = nil
  floating_state.buf = nil
  floating_state.closed = true
end

-----------------------------------------------------------------------
-- Backend Registry
-----------------------------------------------------------------------
local BACKENDS = {
  pyright = {
    package = "pyright",
    binary = "pyright-langserver",
    check_script = function(py_bin, env_bin)
      return string.format([[
PYBIN="%s"
ENV_BIN="%s"
"$PYBIN" -V >/dev/null 2>&1 || exit 2
if [ -x "$ENV_BIN/pyright-langserver" ]; then "$ENV_BIN/pyright-langserver" --version >/dev/null 2>&1 && exit 0; fi
"$PYBIN" -m pip show pyright >/dev/null 2>&1 && exit 0
"$PYBIN" -m pyright.langserver --version >/dev/null 2>&1 && exit 0
exit 1
]], py_bin, env_bin)
    end,
  },
  ty = {
    package = "ty",
    binary = "ty",
    check_script = function(py_bin, env_bin)
      return string.format([[
PYBIN="%s"
ENV_BIN="%s"
"$PYBIN" -V >/dev/null 2>&1 || exit 2
if [ -x "$ENV_BIN/ty" ]; then "$ENV_BIN/ty" server --help >/dev/null 2>&1 && exit 0; fi
"$PYBIN" -m pip show ty >/dev/null 2>&1 && exit 0
exit 1
]], py_bin, env_bin)
    end,
  },
}

-----------------------------------------------------------------------
-- ensure_backend_installed_async(backend_name, py_bin, cb, opts)
-- 功能：通用的backend安装检查和安装函数
-----------------------------------------------------------------------
local function ensure_backend_installed_async(backend_name, py_bin, cb, opts)
  opts = opts or {}
  local quiet = opts.quiet == true
  local env = config.get("env")
  local backend_cfg = BACKENDS[backend_name]

  if not backend_cfg then
    notify(string.format("[installer] unknown backend: %s", backend_name), vim.log.levels.ERROR)
    cb(false, false)
    return
  end

  local function run_check_async(next_cb)
    local env_bin = env .. "/bin"
    local script = backend_cfg.check_script(py_bin, env_bin)
    ssh_runner.execute_remote_script(script, function(ok, out, code)
      state.set_last_check_out(out)
      next_cb(ok, out, code)
    end, { timeout = 15000, quiet = quiet })
  end

  run_check_async(function(ok, out, code)
    if ok then
      cb(true, false)
      return
    end

    notify(
      string.format("[installer] %s not found (code=%d). Output:\n%s", backend_name, code, table.concat(out or {}, "\n")),
      vim.log.levels.WARN,
      quiet
    )

    local auto_install = config.get("auto_install")
    local proceed_install = auto_install

    if not proceed_install then
      local ans = vim.fn.input(string.format("%s not detected in remote env. Install via pip? [y/N]: ", backend_cfg.package))
      proceed_install = ans:lower() == "y"
    else
      notify(string.format("[installer] auto-installing %s ... (%s)", backend_name, env), vim.log.levels.INFO, quiet)
    end

    if not proceed_install then
      notify(string.format("[installer] skipping %s install; LSP may fail to start", backend_name), vim.log.levels.WARN, quiet)
      cb(false, true)
      return
    end

    local install_script = string.format([[
PYBIN="%s"
if ! "$PYBIN" -V >/dev/null 2>&1; then echo "python not runnable: $PYBIN" >&2; exit 2; fi
"$PYBIN" -c "import sys; print('[installer] using python', sys.executable)"
"$PYBIN" -m pip install %s
]], py_bin, backend_cfg.package)

    ssh_runner.execute_remote_script(install_script, function(ok2, output, code2)
      if not ok2 then
        notify(
          string.format("[installer] pip install %s failed: %s", backend_name, table.concat(output or {}, "\n")),
          vim.log.levels.ERROR
        )
        cb(false, false)
        return
      end

      notify(string.format("[installer] pip install output:\n%s", table.concat(output or {}, "\n")), vim.log.levels.INFO, quiet)

      run_check_async(function(ok3, out3, code3)
        if not ok3 then
          notify(
            string.format(
              "[installer] %s still missing after install (code=%d). Output:\n%s",
              backend_name,
              code3,
              table.concat(out3 or {}, "\n")
            ),
            vim.log.levels.ERROR
          )
          cb(false, false)
          return
        end
        notify(string.format("[installer] %s installed and validated", backend_name), vim.log.levels.INFO, quiet)
        cb(true, false)
      end)
    end, { timeout = 120000 })
  end)
end

-----------------------------------------------------------------------
-- M.ensure_pyright_installed_async(py_bin, cb, opts)
-- 功能：确保 pyright 已安装
-- 参数：
--   py_bin - python 路径
--   cb     - 回调函数 cb(success, declined)
--   opts   - 选项：
--            quiet: 是否静默执行
-- 返回：无
function M.ensure_pyright_installed_async(py_bin, cb, opts)
  ensure_backend_installed_async("pyright", py_bin, cb, opts)
end

-----------------------------------------------------------------------
-- M.ensure_ty_installed_async(py_bin, cb, opts)
-- 功能：确保 ty 已安装
-- 参数：
--   py_bin - python 路径
--   cb     - 回调函数 cb(success, declined)
--   opts   - 选项：
--            quiet: 是否静默执行
-- 返回：无
function M.ensure_ty_installed_async(py_bin, cb, opts)
  ensure_backend_installed_async("ty", py_bin, cb, opts)
end

-----------------------------------------------------------------------
-- M.ensure_lsp_installed_async(py_bin, cb, opts)
-- 功能：根据backend配置确保对应的LSP已安装
-- 参数：
--   py_bin - python 路径
--   cb     - 回调函数 cb(success, declined)
--   opts   - 选项：
--            quiet: 是否静默执行
-- 返回：无
function M.ensure_lsp_installed_async(py_bin, cb, opts)
  local backend = config.get("backend")
  if backend == "ty" then
    M.ensure_ty_installed_async(py_bin, cb, opts)
  else
    M.ensure_pyright_installed_async(py_bin, cb, opts)
  end
end

-----------------------------------------------------------------------
-- M.ensure_env_and_pyright_async(cb, opts)
-- 功能：确保环境配置正确且 LSP 可用
-- 参数：
--   cb   - 回调函数 cb(ready)
--   opts - 选项：
--            prompt: 是否允许提示用户，默认true
--            quiet:  是否静默执行
function M.ensure_env_and_pyright_async(cb, opts)
  opts = opts or {}
  local prompt_allowed = opts.prompt ~= false
  local quiet = opts.quiet == true

  local function notify(msg, level)
    if quiet then
      return
    end
    vim.notify(msg, level or vim.log.levels.INFO)
  end

  -- 检查主机配置
  local host = config.get("host")
  if not host or host == "" then
    if prompt_allowed then
      local h = vim.fn.input("Remote SSH host (as in ~/.ssh/config): ")
      h = vim.fn.trim(h)
      if h ~= nil and h ~= "" then
        config.set({ host = h })
      end
    end

    host = config.get("host")
    if not host or host == "" then
      if not quiet then
        vim.notify(
          "[installer] host not set; skipping start. Set with :PyrightRemoteHost <host> or open an oil-ssh:// buffer.",
          vim.log.levels.WARN
        )
      end
      cb(false)
      return
    end
  end

  -- 检查是否已经验证过此环境
  local env = config.get("env")
  local backend = config.get("backend")
  if env and state.has_valid_env(backend .. ":" .. host, env) then
    state.set_prompted_env(true)
    cb(true)
    return
  end

  local function continue_with_py(py_bin)
    local function handle_missing_py()
      if not prompt_allowed then
        notify(
          string.format(
            "[installer] remote python unavailable; skipping start. host=%s path=%s",
            host,
            py_bin
          ),
          vim.log.levels.ERROR
        )
        local cache_key = string.format("%s|%s|%s:missing", backend, host, env or "")
        state.set_checked_env(cache_key)
        cb(false)
        return
      end

      local ok_input, retry = pcall(
        vim.fn.input,
        string.format(
          "Remote python missing or not executable (host=%s code=%d): %s\nOutput:\n%s\nRe-enter remote python path (leave empty to keep current): ",
          host,
          state.get_last_check_out() and 2 or -1,
          py_bin,
          table.concat(state.get_last_check_out() or {}, "\n")
        )
      )

      if not ok_input then
        notify(
          "[installer] prompt unavailable; set :PyrightRemoteEnv /path/to/venv (or g:pyright_remote_env) and retry",
          vim.log.levels.WARN
        )
        local cache_key = string.format("%s|%s|%s:missing", backend, host, env or "")
        state.set_checked_env(cache_key)
        cb(false)
        return
      end

      retry = vim.fn.trim(retry or "")
      if retry ~= "" then
        py_bin = retry
        local path = require("oil_pyright_remote.path")
        local env_dir = path.normalize_env(retry)
        config.set({ env = env_dir })
        py_bin = env_dir and (env_dir .. "/bin/python") or retry

        -- 递归检查新的路径
        ssh_runner.python_exists_async(py_bin, function(ok_py2)
          if not ok_py2 then
            notify(
              string.format(
                "[installer] remote python unavailable; skipping start. host=%s path=%s",
                host,
                py_bin
              ),
              vim.log.levels.ERROR
            )
            local cache_key = string.format("%s|%s|%s:missing", backend, host, config.get("env") or "")
            state.set_checked_env(cache_key)
            cb(false)
            return
          end

          M.ensure_lsp_installed_async(py_bin, function(ok4, declined4)
            local cache_key = string.format("%s|%s|%s", backend, host, config.get("env") or "")
            if ok4 then
              state.set_checked_env(cache_key)
              state.mark_valid_env(backend .. ":" .. host, config.get("env"))
              cb(true)
            else
              if declined4 then
                state.set_checked_env(cache_key .. ":missing")
              end
              cb(false)
            end
          end, opts)
        end)
        return
      end

      notify(
        string.format(
          "[installer] remote python unavailable; skipping start. host=%s path=%s",
          host,
          py_bin
        ),
        vim.log.levels.ERROR
      )
      local cache_key = string.format("%s|%s|%s:missing", backend, host, env or "")
      state.set_checked_env(cache_key)
      cb(false)
    end

    ssh_runner.python_exists_async(py_bin, function(ok_py, out_py, code_py)
      if not ok_py then
        -- 调度到安全上下文执行用户交互
        vim.schedule(handle_missing_py)
        return
      end

      local cache_key = string.format("%s|%s|%s", backend, host, config.get("env") or "")
      local checked_env = state.get_checked_env()

      if checked_env == cache_key then
        cb(true)
        return
      end
      if checked_env == cache_key .. ":missing" then
        cb(false)
        return
      end

      notify("[installer] checking remote python / pyright ...")

      M.ensure_lsp_installed_async(py_bin, function(ok, declined)
        if ok then
          state.set_checked_env(cache_key)
          state.mark_valid_env(backend .. ":" .. host, config.get("env"))
          state.remember_env(host, config.get("env"))
          cb(true)
          return
        end
        if declined then
          state.set_checked_env(cache_key .. ":missing")
        end
        cb(false)
      end, opts)
    end)
  end

  -- 检查是否已提示过环境
  if not state.get_prompted_env() then
    state.set_prompted_env(true)  -- 立即置位，防止重复触发
    M.prompt_env_path_async(function(py_bin)
      if not py_bin or py_bin == "" then
        cb(false)
        return
      end
      continue_with_py(py_bin)
    end, { prompt = prompt_allowed })
  else
    local env = config.get("env")
    local py_bin = env and (env .. "/bin/python") or "/bin/python"
    continue_with_py(py_bin)
  end
end

-----------------------------------------------------------------------
-- M.prewarm_env_async(host, env)
-- 功能：预热环境（预先验证和安装 pyright）
-- 参数：
--   host - 主机名，可选
--   env  - 环境路径，可选
function M.prewarm_env_async(host, env)
  local path = require("oil_pyright_remote.path")
  host = host or config.get("host")
  env = path.normalize_env(env or config.get("env"))

  if not host or host == "" or not env or env == "" then
    return
  end

  local backend = config.get("backend")
  if state.has_valid_env(backend .. ":" .. host, env) then
    return
  end

  local py_bin = env .. "/bin/python"
  ssh_runner.python_exists_async(py_bin, function(ok_py)
    if not ok_py then
      return
    end
    M.ensure_lsp_installed_async(py_bin, function(ok, _)
      if ok then
        state.mark_valid_env(backend .. ":" .. host, env)
        state.remember_env(host, env)
      end
    end, { quiet = true })
  end)
end

return M
