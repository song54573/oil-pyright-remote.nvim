--[[
oil_pyright_remote: start pyright-langserver over SSH and map LSP I/O back to
oil-ssh buffers. Handles remote host/env/root state, remote python/pyright
verification/installation, custom handlers + reconnect logic, and user commands
to switch host/env/root quickly.
]]

local jump_with_oil
local pyright_remote_cfg
local enable_pyright_remote
local prewarm_env_async
local M = {}

local function normalize_env(env)
  if not env or env == "" then
    return nil
  end
  local e = env
  e = e:gsub("^%s+", "")
  e = e:gsub("%s+$", "")
  e = e:gsub("/+$", "")
  e = e:gsub("/bin/python$", "")
  e = e:gsub("/bin$", "")
  return e
end -- normalize_env

local state = {
  -- host = vim.g.pyright_remote_host or vim.env.PYRIGHT_REMOTE_HOST or "withai20",
  host = vim.g.pyright_remote_host or vim.env.PYRIGHT_REMOTE_HOST,
  -- env  = normalize_env(vim.g.pyright_remote_env or vim.env.PYRIGHT_REMOTE_ENV or "/mnt/data1/wqs/envs/bleeding_env"),
  env = normalize_env(vim.g.pyright_remote_env or vim.env.PYRIGHT_REMOTE_ENV),
  -- root = vim.g.pyright_remote_workspace_root or vim.env.PYRIGHT_REMOTE_ROOT or "",
  root = vim.g.pyright_remote_workspace_root or vim.env.PYRIGHT_REMOTE_ROOT,
  auto_install = vim.g.pyright_remote_auto_install,
  start_notify = vim.g.pyright_remote_start_notify,
}
-- normalize unset values to empty strings so string ops don't error
state.host = state.host or ""
state.env = state.env or ""
state.root = state.root or ""
if state.auto_install == nil then
  state.auto_install = false
end
if state.start_notify == nil then
  state.start_notify = false
end
vim.g.pyright_remote_host = state.host
vim.g.pyright_remote_env = state.env
vim.g.pyright_remote_workspace_root = state.root
vim.g.pyright_remote_auto_install = state.auto_install

local uv = vim.uv or vim.loop

-- e.g. ~/.local/share/nvim/pyright_remote_envs.json
local env_store_path = vim.fn.stdpath("data") .. "/pyright_remote_envs.json"
local env_store_loaded = false
local env_store = {}

local valid_store_path = vim.fn.stdpath("data") .. "/pyright_remote_validated.json"
local valid_store_loaded = false
local valid_store = {}

local function load_env_store()
  if env_store_loaded then
    return env_store
  end
  env_store_loaded = true
  env_store = {}
  local ok, data = pcall(vim.fn.readfile, env_store_path)
  if ok and data and #data > 0 then
    local ok2, decoded = pcall(vim.fn.json_decode, table.concat(data, "\n"))
    if ok2 and type(decoded) == "table" then
      env_store = decoded
    end
  end
  return env_store
end -- load_env_store

local function save_env_store()
  if not env_store_loaded then
    return
  end
  local dir = vim.fn.fnamemodify(env_store_path, ":h")
  pcall(vim.fn.mkdir, dir, "p")
  local ok, encoded = pcall(vim.fn.json_encode, env_store or {})
  if not ok then
    return
  end
  pcall(vim.fn.writefile, { encoded }, env_store_path)
end -- save_env_store

local function load_valid_store()
  if valid_store_loaded then
    return valid_store
  end
  valid_store_loaded = true
  valid_store = {}
  local ok, data = pcall(vim.fn.readfile, valid_store_path)
  if ok and data and #data > 0 then
    local ok2, decoded = pcall(vim.fn.json_decode, table.concat(data, "\n"))
    if ok2 and type(decoded) == "table" then
      valid_store = decoded
    end
  end
  return valid_store
end -- load_valid_store

local function save_valid_store()
  if not valid_store_loaded then
    return
  end
  local dir = vim.fn.fnamemodify(valid_store_path, ":h")
  pcall(vim.fn.mkdir, dir, "p")
  local ok, encoded = pcall(vim.fn.json_encode, valid_store or {})
  if not ok then
    return
  end
  pcall(vim.fn.writefile, { encoded }, valid_store_path)
end -- save_valid_store

local function list_envs(host)
  local store = load_env_store()
  local entry = store[host or state.host]
  if entry and entry.envs then
    return entry.envs
  end
  return {}
end

local function remember_env(host, env)
  if not host or host == "" or not env or env == "" then
    return
  end
  env = normalize_env(env)
  local store = load_env_store()
  store[host] = store[host] or { envs = {}, last_env = nil }
  local entry = store[host]
  entry.last_env = env
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
  table.insert(entry.envs, 1, env)
  save_env_store()
end

local function has_valid_env(host, env)
  host = host or state.host
  env = normalize_env(env)
  if not host or host == "" or not env or env == "" then
    return false
  end
  local store = load_valid_store()
  return store[host] and store[host][env] == true
end

local function mark_valid_env(host, env)
  host = host or state.host
  env = normalize_env(env)
  if not host or host == "" or not env or env == "" then
    return
  end
  local store = load_valid_store()
  store[host] = store[host] or {}
  store[host][env] = true
  save_valid_store()
end

local function get_last_env(host)
  local store = load_env_store()
  local entry = store[host or state.host]
  if entry and entry.last_env and entry.last_env ~= "" then
    return normalize_env(entry.last_env)
  end
end

local function forget_env(host, env)
  host = host or state.host
  if not host or host == "" then
    return
  end
  local store = load_env_store()
  if not store[host] then
    return
  end
  if not env or env == "" then
    store[host] = nil
    local vstore = load_valid_store()
    vstore[host] = nil
    save_valid_store()
    save_env_store()
    return
  end
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
  local vstore = load_valid_store()
  if vstore[host] then
    vstore[host][env] = nil
    if vim.tbl_isempty(vstore[host]) then
      vstore[host] = nil
    end
    save_valid_store()
  end
  save_env_store()
end

local function select_env_async(host, cb)
  local envs = list_envs(host)
  if not envs or #envs == 0 then
    cb(nil)
    return
  end
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

  local closed = false
  local cursor = 1
  vim.api.nvim_win_set_cursor(win, { cursor, 0 })

  local function finish(choice)
    if closed then
      return
    end
    closed = true
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    cb(choice)
  end

  local function move(delta)
    cursor = math.max(1, math.min(cursor + delta, #envs))
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { cursor, 0 })
    end
  end

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

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    once = true,
    callback = function()
      finish(nil)
    end,
  })
end

local function remote_bash(script)
  return { "ssh", state.host, script }
end

local function run_async(cmd, cb)
  local stdout, stderr = {}, {}
  local jid = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr, line)
          end
        end
      end
    end,
    on_exit = function(_, code, signal)
      cb(code == 0, stdout, code, signal, stderr)
    end,
  })
  if jid <= 0 then
    cb(false, {}, 1, 0, { "jobstart failed: " .. tostring(jid) })
  end
end -- run_async

local function set_state(key, val)
  if val and val ~= "" and state[key] ~= val then
    state[key] = val
    if key == "host" or key == "env" then
      checked_env = nil
      prompted_env = false
    end
    if key == "host" then
      vim.g.pyright_remote_host = val
      local stored_env = get_last_env(val)
      if stored_env then
        state.env = stored_env
        vim.g.pyright_remote_env = stored_env
      end
    elseif key == "env" then
      val = normalize_env(val)
      state.env = val
      vim.g.pyright_remote_env = val
      remember_env(state.host, val)
    elseif key == "root" then
      vim.g.pyright_remote_workspace_root = val
    elseif key == "auto_install" then
      vim.g.pyright_remote_auto_install = val and true or false
    end
  end
end

local prompted_env = false
local checked_env = nil
local last_check_out = nil

local function prompt_env_path_async(cb, opts)
  opts = opts or {}
  local allow_prompt = opts.prompt ~= false

  if not allow_prompt then
    cb(nil)
    return
  end

  local function ask_python()
    local default_py = (state.env or "") .. "/bin/python"
    if default_py == "/bin/python" then
      default_py = ""
      set_state("env", "")
    end
    local input = vim.fn.input(string.format("Remote python path (leave empty to keep current): [%s] ", default_py))
    input = vim.fn.trim(input)
    if input ~= nil and input ~= "" then
      local env_dir = input:gsub("/bin/python$", ""):gsub("/?$", "")
      set_state("env", env_dir)
      cb(env_dir .. "/bin/python")
      return
    end
    cb(default_py)
  end

  if not state.env or state.env == "" then
    select_env_async(state.host, function(choice)
      if choice and choice ~= "" then
        set_state("env", choice)
      end
      if not state.env or state.env == "" then
        local input_env = vim.fn.input("Remote virtualenv root (without /bin/python): ")
        input_env = vim.fn.trim(input_env)
        if input_env ~= nil and input_env ~= "" then
          set_state("env", input_env)
        end
      end
      ask_python()
    end)
  else
    ask_python()
  end
end

local function ensure_pyright_installed_async(py_bin, cb, opts)
  opts = opts or {}
  local quiet = opts.quiet == true
  local function notify(msg, level)
    if quiet then
      return
    end
    vim.notify(msg, level or vim.log.levels.INFO)
  end

  local function run_check_async(next_cb)
    local env_bin = state.env .. "/bin"
    local script = string.format(
      [[
PYBIN="%s"
ENV_BIN="%s"
"$PYBIN" -V >/dev/null 2>&1 || exit 2
if [ -x "$ENV_BIN/pyright-langserver" ]; then "$ENV_BIN/pyright-langserver" --version >/dev/null 2>&1 && exit 0; fi
if command -v pyright-langserver >/dev/null 2>&1; then pyright-langserver --version >/dev/null 2>&1 && exit 0; fi
"$PYBIN" -m pip show pyright >/dev/null 2>&1 && exit 0
"$PYBIN" -m pyright.langserver --version >/dev/null 2>&1 && exit 0
exit 1
]],
      py_bin,
      env_bin
    )
    run_async(remote_bash(script), function(ok, out, code, signal)
      last_check_out = out
      next_cb(ok, out, code, signal)
    end)
  end

  run_check_async(function(ok, out, code)
    if ok then
      cb(true, false)
      return
    end

    notify(
      string.format("[pyright_remote] pyright not found (code=%d). Output:\n%s", code, table.concat(out or {}, "\n")),
      vim.log.levels.WARN
    )

    local proceed_install = state.auto_install
    if not proceed_install then
      local ans = vim.fn.input("Pyright not detected in remote env. Install via pip? [y/N]: ")
      proceed_install = ans:lower() == "y"
    else
      notify(string.format("[pyright_remote] auto-installing pyright ... (%s)", state.env), vim.log.levels.INFO)
    end

    if not proceed_install then
      notify("[pyright_remote] skipping pyright install; LSP may fail to start", vim.log.levels.WARN)
      cb(false, true)
      return
    end

    local install_cmd = remote_bash(string.format(
      [[
PYBIN="%s"
if ! "$PYBIN" -V >/dev/null 2>&1; then echo "python not runnable: $PYBIN" >&2; exit 2; fi
"$PYBIN" -c "import sys; print('[pyright_remote] using python', sys.executable)"
"$PYBIN" -m pip install --no-user pyright
    ]],
      py_bin
    ))

    run_async(install_cmd, function(ok2, output, code2)
      if not ok2 then
        notify(
          "[pyright_remote] pip install pyright failed: " .. table.concat(output or {}, "\n"),
          vim.log.levels.ERROR
        )
        cb(false, false)
        return
      end
      notify("[pyright_remote] pip install output:\n" .. table.concat(output or {}, "\n"), vim.log.levels.INFO)

      run_check_async(function(ok3, out3, code3)
        if not ok3 then
          notify(
            string.format(
              "[pyright_remote] pyright still missing after install (code=%d). Output:\n%s",
              code3,
              table.concat(out3 or {}, "\n")
            ),
            vim.log.levels.ERROR
          )
          cb(false, false)
          return
        end
        notify("[pyright_remote] pyright installed and validated", vim.log.levels.INFO)
        cb(true, false)
      end)
    end)
  end)
end

local function python_exists_async(path, cb)
  if not path or path == "" then
    cb(false, { "empty path" }, 1)
    return
  end
  local cmd = remote_bash(string.format([[test -x "%s"]], path))
  run_async(cmd, function(ok, out, code, signal)
    if ok then
      cb(true, out, code, signal)
      return
    end

    local cmd2 = remote_bash(string.format([["%s" -V]], path))
    run_async(cmd2, function(ok2, out2, code2, signal2)
      local merged = {}
      vim.list_extend(merged, out or {})
      vim.list_extend(merged, out2 or {})
      cb(ok2, merged, code2 ~= 0 and code2 or code)
    end)
  end)
end

local function ensure_env_and_pyright_async(cb, opts)
  opts = opts or {}
  local prompt_allowed = opts.prompt ~= false
  local quiet = opts.quiet == true

  local function notify(msg, level)
    if quiet then
      return
    end
    vim.notify(msg, level or vim.log.levels.INFO)
  end

  -- host is required for any remote work; prompt once then bail quietly
  if not state.host or state.host == "" then
    if prompt_allowed then
      local h = vim.fn.input("Remote SSH host (as in ~/.ssh/config): ")
      h = vim.fn.trim(h)
      if h ~= nil and h ~= "" then
        set_state("host", h)
      end
    end
    if not state.host or state.host == "" then
      if not quiet then
        vim.notify(
          "[pyright_remote] host not set; skipping start. Set with :PyrightRemoteHost <host> or open an oil-ssh:// buffer.",
          vim.log.levels.WARN
        )
      end
      cb(false)
      return
    end
  end

  if state.env and has_valid_env(state.host, state.env) then
    prompted_env = true
    cb(true)
    return
  end

  local function continue_with_py(py_bin)
    local host = state.host ~= "" and state.host or "?"
    python_exists_async(py_bin, function(ok_py, out_py, code_py)
      if not ok_py then
        local function handle_missing_py()
          if not prompt_allowed then
            vim.notify(
              string.format(
                "[pyright_remote] remote python unavailable; skipping start. host=%s path=%s",
                host,
                py_bin
              ),
              vim.log.levels.ERROR
            )
            checked_env = string.format("%s|%s:missing", host, state.env or "")
            cb(false)
            return
          end

          local retry = vim.fn.input(
            string.format(
              "Remote python missing or not executable (host=%s code=%d): %s\nOutput:\n%s\nRe-enter remote python path (leave empty to keep current): ",
              host,
              code_py or -1,
              py_bin,
              table.concat(out_py or {}, "\n")
            )
          )
          retry = vim.fn.trim(retry)
          if retry ~= nil and retry ~= "" then
            py_bin = retry
            local env_dir = normalize_env(retry)
            set_state("env", env_dir)
            py_bin = env_dir and (env_dir .. "/bin/python") or retry
            python_exists_async(py_bin, function(ok_py2, out_py2, code_py2)
              if not ok_py2 then
                vim.notify(
                  string.format(
                    "[pyright_remote] remote python unavailable; skipping start. host=%s path=%s",
                    host,
                    py_bin
                  ),
                  vim.log.levels.ERROR
                )
                checked_env = string.format("%s|%s:missing", host, state.env or "")
                cb(false)
                return
              end
              ensure_pyright_installed_async(py_bin, function(ok4, declined4)
                local cache_key = string.format("%s|%s", host, state.env or "")
                if ok4 then
                  checked_env = cache_key
                  mark_valid_env(state.host, state.env)
                  cb(true)
                else
                  if declined4 then
                    checked_env = cache_key .. ":missing"
                  end
                  cb(false)
                end
              end, opts)
            end)
            return
          end

          vim.notify(
            string.format(
              "[pyright_remote] remote python unavailable; skipping start. host=%s path=%s",
              host,
              py_bin
            ),
            vim.log.levels.ERROR
          )
          checked_env = string.format("%s|%s:missing", host, state.env or "")
          cb(false)
        end

        if vim.in_fast_event() then
          vim.schedule(handle_missing_py)
        else
          handle_missing_py()
        end
        return
      end

      local cache_key = string.format("%s|%s", host, state.env or "")
      if checked_env == cache_key then
        cb(true)
        return
      end
      if checked_env == cache_key .. ":missing" then
        cb(false)
        return
      end

      notify("[pyright_remote] checking remote python / pyright ...")

      ensure_pyright_installed_async(py_bin, function(ok, declined)
        if ok then
          checked_env = cache_key
          mark_valid_env(state.host, state.env)
          cb(true)
          return
        end
        if declined then
          checked_env = cache_key .. ":missing"
        end
        cb(false)
      end, opts)
    end)
  end

  if not prompted_env then
    prompt_env_path_async(function(py_bin)
      prompted_env = true
      if not py_bin or py_bin == "" then
        cb(false)
        return
      end
      continue_with_py(py_bin)
    end, { prompt = prompt_allowed })
  else
    local py_bin = state.env and (state.env .. "/bin/python") or "/bin/python"
    continue_with_py(py_bin)
  end
end

local on_attach = function(client, bufnr)
  local bufmap = function(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
  end

  bufmap("n", "gd", vim.lsp.buf.definition, "Go to definition")
  bufmap("n", "K", vim.lsp.buf.hover, "Hover")
  bufmap("n", "gr", vim.lsp.buf.references, "References")
  bufmap("n", "<leader>rn", vim.lsp.buf.rename, "Rename")
  bufmap("n", "<leader>ac", vim.lsp.buf.code_action, "Code action")

  if client.name == "pyright_remote" then
    client.server_capabilities.documentFormattingProvider = false
    pcall(vim.diagnostic.config, {
      virtual_text = { prefix = "●", spacing = 2 },
      signs = true,
      underline = true,
      update_in_insert = false,
      severity_sort = true,
    })
    pcall(vim.diagnostic.enable, bufnr)
    local function req(method)
      return function()
        local name = vim.api.nvim_buf_get_name(bufnr)
        local h = name:match("^oil%-ssh://([^/]+)//")
        if h and h ~= "" then
          state.host = h
        end
        local params = vim.lsp.util.make_position_params(0, client.offset_encoding or "utf-16")
        vim.lsp.buf_request(bufnr, method, params, pyright_remote_cfg.handlers[method] or jump_with_oil)
      end
    end
    bufmap("n", "gd", req("textDocument/definition"), "Go to definition (remote)")
    bufmap("n", "gi", req("textDocument/implementation"), "Go to implementation (remote)")
    bufmap("n", "gD", req("textDocument/declaration"), "Go to declaration (remote)")
    bufmap("n", "gr", req("textDocument/references"), "References (remote)")
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

local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.workspace = capabilities.workspace or {}
capabilities.workspace.didChangeWatchedFiles = { dynamicRegistration = false }
-- capabilities = require("cmp_nvim_lsp").default_capabilities(capabilities)

-----------------------------------------------------
-----------------------------------------------------
local function remote_root()
  return state.root
end
local function remote_root_for_cmd()
  return nil
end

local orig_uri_from_bufnr = vim.uri_from_bufnr
vim.uri_from_bufnr = function(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local host, path = name:match("^oil%-ssh://([^/]+)(/.+)$")
  if host and path then
    if path:sub(1, 2) == "//" then
      path = path:sub(2)
    end
    return vim.uri_from_fname(path)
  end
  return orig_uri_from_bufnr(bufnr)
end

local function to_oil_path(fname, host)
  host = host or state.host
  if fname:sub(1, 1) ~= "/" then
    return string.format("oil-ssh://%s/%s", host, fname)
  end
  return string.format("oil-ssh://%s//%s", host, fname:gsub("^/+", ""))
end

local function from_oil_path(name)
  local host, path = name:match("^oil%-ssh://([^/]+)//(.+)$")
  if host and path then
    return "/" .. path:gsub("^/+", "")
  end
  host, path = name:match("^oil%-ssh://([^/]+)/(.*)$")
  if host and path then
    if path:sub(1, 1) ~= "/" then
      path = "/" .. path
    end
    return path
  end
end

local function location_to_oil_item(loc)
  local uri = loc.uri or loc.targetUri
  if not uri then
    return
  end
  local range = loc.range or loc.targetSelectionRange or loc.targetRange
  local fname = vim.uri_to_fname(uri)
  local oil_path = to_oil_path(fname, state.host)
  local line1 = (range and range.start and range.start.line or 0) + 1 -- nvim cursor 1-based
  local col0 = (range and range.start and range.start.character or 0)
  return {
    filename = oil_path,
    lnum = line1,
    col = col0,
    range = range,
    uri = uri,
  }
end

local function lsp_get_clients(opts)
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

local reconnect = {
  timer = nil,
  attempted = false,
  suppress_count = 0,
  last_buf = nil,
}

local function stop_reconnect_timer()
  if reconnect.timer then
    reconnect.timer:stop()
    reconnect.timer:close()
    reconnect.timer = nil
  end
end

local function pick_reconnect_buf(client)
  if client and client.attached_buffers then
    for buf, attached in pairs(client.attached_buffers) do
      if attached and vim.api.nvim_buf_is_valid(buf) then
        return buf
      end
    end
  end
  if reconnect.last_buf and vim.api.nvim_buf_is_valid(reconnect.last_buf) then
    return reconnect.last_buf
  end
end

local function schedule_reconnect(bufnr, exit_code, signal)
  if reconnect.attempted then
    return
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  reconnect.attempted = true
  stop_reconnect_timer()

  reconnect.timer = uv.new_timer()
  reconnect.timer:start(20000, 0, function()
    stop_reconnect_timer()
    vim.schedule(function()
      if reconnect.suppress_count > 0 then
        return
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then
        vim.notify("[pyright_remote] reconnect skipped: buffer no longer valid", vim.log.levels.WARN)
        return
      end
      vim.notify("[pyright_remote] LSP disconnected, retrying once ...", vim.log.levels.WARN)
      local ok, err = pcall(enable_pyright_remote, bufnr)
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

local function pyright_on_exit(code, signal, client_id)
  if reconnect.suppress_count > 0 then
    reconnect.suppress_count = reconnect.suppress_count - 1
    return
  end
  if (code == 0 or code == nil) and (signal == 0 or signal == nil) then
    return
  end
  local client = client_id and vim.lsp.get_client_by_id and vim.lsp.get_client_by_id(client_id)
  local target_buf = pick_reconnect_buf(client)
  if target_buf then
    schedule_reconnect(target_buf, code, signal)
  end
end

local function build_cmd()
  local env_bin = string.format("%s/bin", state.env)
  local pyright_bin = string.format([[%s/pyright-langserver]], env_bin)
  local py_bin = string.format([[%s/python]], env_bin)

  local cmd_str = string.format(
    [[
      PYRIGHT_BIN="%s"
      PY_BIN="%s"
      if [ -x "$PYRIGHT_BIN" ]; then
        exec "$PYRIGHT_BIN" --stdio
      elif [ -x "$PY_BIN" ]; then
        exec "$PY_BIN" -m pyright.langserver --stdio
      else
        echo "pyright executable not found under %s" >&2
        exit 127
      fi]],
    pyright_bin,
    py_bin,
    env_bin
  )

  return {
    "ssh",
    state.host,
    cmd_str,
  }
end

pyright_remote_cfg = {
  name = "pyright_remote",
  cmd = build_cmd(),

  filetypes = { "python" },

  root_markers = {
    "pyproject.toml",
    "setup.py",
    "setup.cfg",
    "requirements.txt",
    ".git",
  },

  -- root_dir = "/home/user/project",

  before_init = function(params, config)
    params.processId = vim.NIL
  end,

  on_exit = pyright_on_exit,

  handlers = {},

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

jump_with_oil = function(err, result, ctx, _)
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
    state.host = cur_host
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
    local oil_uri = to_oil_path(fname, state.host)
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

  local function goto_loc(loc)
    local fname = vim.uri_to_fname(loc.uri)
    if not fname or fname == "" then
      return
    end

    vim.cmd("edit " .. vim.fn.fnameescape(fname))
    local bufnr = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()

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

pyright_remote_cfg.handlers = {
  ["textDocument/publishDiagnostics"] = function(err, params, ctx, cfg)
    if params and params.uri then
      local fname = vim.uri_to_fname(params.uri)
      params.uri = to_oil_path(fname, state.host)
      if params.diagnostics then
        for _, d in ipairs(params.diagnostics) do
          if d.relatedInformation then
            for _, info in ipairs(d.relatedInformation) do
              local ri_uri = info.location and info.location.uri
              if ri_uri then
                local rf = vim.uri_to_fname(ri_uri)
                info.location.uri = to_oil_path(rf, state.host)
              end
            end
          end
        end
      end
    end
    return vim.lsp.handlers["textDocument/publishDiagnostics"](err, params, ctx, cfg)
  end,
  ["textDocument/definition"] = jump_with_oil,
  ["textDocument/typeDefinition"] = jump_with_oil,
  ["textDocument/declaration"] = jump_with_oil,
  ["textDocument/implementation"] = jump_with_oil,
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
      local item = location_to_oil_item(loc)
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

if vim.lsp and vim.lsp.config then
  vim.lsp.config("pyright_remote", pyright_remote_cfg)
end

function enable_pyright_remote(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  reconnect.last_buf = bufnr
  stop_reconnect_timer()

  local name = vim.api.nvim_buf_get_name(bufnr)
  local h = name:match("^oil%-ssh://([^/]+)//")
  if h and h ~= "" then
    set_state("host", h)
  end

  local function start_client()
    local existing = lsp_get_clients({ bufnr = bufnr, name = "pyright_remote" })
    if existing and #existing > 0 then
      return
    end

    local config = vim.deepcopy(pyright_remote_cfg)

    local bufname = vim.api.nvim_buf_get_name(bufnr)
    local remote_path = from_oil_path(bufname) or vim.fn.fnamemodify(bufname, ":p")
    local root_dir = (state.root and state.root ~= "") and state.root or vim.fn.fnamemodify(remote_path, ":h")
    if not root_dir or root_dir == "" then
      root_dir = "/"
    end
    config.root_dir = root_dir
    config.workspace_folders = {
      {
        uri = vim.uri_from_fname(root_dir),
        name = root_dir,
      },
    }

    config = vim.tbl_deep_extend("force", {}, config, {
      name = "pyright_remote",
      on_attach = on_attach,
      capabilities = capabilities,
      bufnr = bufnr,
      settings = {
        python = {
          analysis = {
            typeCheckingMode = "basic",
            autoSearchPaths = true,
            useLibraryCodeForTypes = true,
            autoImportCompletions = true,
          },
          pythonPath = state.env .. "/bin/python",
        },
      },
    })

    config.cmd = build_cmd()

    if state.start_notify then
      vim.schedule(function()
        pcall(
          vim.notify,
          string.format(
            "[pyright_remote] starting. root=%s file=%s",
            tostring(config.root_dir),
            vim.api.nvim_buf_get_name(bufnr)
          ),
          vim.log.levels.INFO
        )
      end)
    end
    local client_id = vim.lsp.start(config)
    if client_id then
      reconnect.attempted = false
    end
    return client_id
  end

  ensure_env_and_pyright_async(function(ok)
    if not ok then
      return
    end
    start_client()
  end)
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = "python",
  callback = function(args)
    enable_pyright_remote(args.buf)
  end,
})

local function kick_existing_python()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "python" then
      pcall(enable_pyright_remote, buf)
    end
  end
end

-----------------------------------------------------
-----------------------------------------------------
vim.diagnostic.config({
  virtual_text = { prefix = "●", spacing = 2 },
  signs = true,
  underline = true,
  update_in_insert = false,
  severity_sort = true,
})

local diag_signs = { Error = "E", Warn = "W", Hint = "H", Info = "I" }
for type, icon in pairs(diag_signs) do
  local hl = "DiagnosticSign" .. type
  vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = "" })
end

vim.keymap.set("n", "<leader>e", function()
  vim.diagnostic.open_float(nil, { scope = "line" })
end, { desc = "Line diagnostics" })

vim.api.nvim_create_user_command("DiagVirtualTextOn", function()
  vim.diagnostic.config({ virtual_text = { prefix = "●", spacing = 2 }, signs = true })
  vim.notify("[diagnostic] virtual text ON", vim.log.levels.INFO)
end, { nargs = 0 })

vim.api.nvim_create_user_command("DiagVirtualTextOff", function()
  vim.diagnostic.config({ virtual_text = false })
  vim.notify("[diagnostic] virtual text OFF", vim.log.levels.INFO)
end, { nargs = 0 })

local function maybe_restart(bufnr)
  stop_reconnect_timer()
  local target_buf = bufnr or vim.api.nvim_get_current_buf()

  local clients = lsp_get_clients({ name = "pyright_remote" })
  if clients and #clients > 0 then
    reconnect.suppress_count = reconnect.suppress_count + #clients
    for _, c in ipairs(clients) do
      vim.lsp.stop_client(c.id)
    end
  end

  enable_pyright_remote(target_buf)
end

local function list_ssh_hosts()
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

local function env_complete(arg_lead)
  local res = {}
  local prefix = arg_lead or ""
  local esc = vim.pesc or function(s)
    return s:gsub("(%W)", "%%%1")
  end
  for _, env in ipairs(list_envs(state.host)) do
    if env:find("^" .. esc(prefix)) then
      table.insert(res, env)
    end
  end
  return res
end

local function prewarm_env_async(host, env)
  host = host or state.host
  env = normalize_env(env)
  if not host or host == "" or not env or env == "" then
    return
  end
  if has_valid_env(host, env) then
    return
  end

  local py_bin = env .. "/bin/python"
  python_exists_async(py_bin, function(ok_py)
    if not ok_py then
      return
    end
    ensure_pyright_installed_async(py_bin, function(ok, _)
      if ok then
        mark_valid_env(host, env)
        remember_env(host, env)
      end
    end, { quiet = true })
  end)
end

vim.schedule(function()
  kick_existing_python()
  prewarm_env_async(state.host, state.env)
end)

vim.api.nvim_create_user_command("PyrightRemoteHost", function(opts)
  if opts.args == "" then
    local cur = (state.host ~= "" and state.host) or "<unset>"
    vim.notify(string.format("[pyright_remote] current host: %s", cur), vim.log.levels.INFO)
    return
  end
  set_state("host", opts.args)
  vim.notify(string.format("[pyright_remote] host -> %s", state.host), vim.log.levels.INFO)
  maybe_restart()
end, { nargs = "?", complete = list_ssh_hosts })

vim.api.nvim_create_user_command("PyrightRemoteEnv", function(opts)
  if opts.args == "" then
    vim.notify(string.format("[pyright_remote] current env: %s", state.env), vim.log.levels.INFO)
    return
  end
  set_state("env", vim.fn.expand(opts.args))
  vim.notify(string.format("[pyright_remote] env -> %s", state.env), vim.log.levels.INFO)
  maybe_restart()
end, { nargs = "?", complete = env_complete })

-- Optional setup to override initial state before autocmds fire.
-- Usage:
-- require("oil_pyright_remote").setup({
--   host = "my-host",
--   env = "/path/to/venv",
--   root = "/remote/project/root",
--   auto_install = true,
--   start_notify = true,
-- })
function M.setup(opts)
  opts = opts or {}
  if opts.host then
    set_state("host", opts.host)
  end
  if opts.env then
    set_state("env", opts.env)
  end
  if opts.root then
    set_state("root", opts.root)
  end
  if opts.auto_install ~= nil then
    set_state("auto_install", opts.auto_install)
  end
  if opts.start_notify ~= nil then
    set_state("start_notify", opts.start_notify)
  end
end

vim.api.nvim_create_user_command("PyrightRemoteRoot", function(opts)
  if opts.args == "" then
    vim.notify(string.format("[pyright_remote] current root: %s", state.root), vim.log.levels.INFO)
    return
  end
  set_state("root", vim.fn.expand(opts.args))
  vim.notify(string.format("[pyright_remote] root -> %s", state.root), vim.log.levels.INFO)
  maybe_restart()
end, { nargs = "?" })

vim.api.nvim_create_user_command("PyrightRemoteRestart", function()
  maybe_restart()
end, { nargs = 0 })

vim.api.nvim_create_user_command("PyrightRemoteEnvForget", function(opts)
  local target = opts.args ~= "" and vim.fn.expand(opts.args) or nil
  forget_env(state.host, target)
  if target then
    vim.notify(string.format("[pyright_remote] removed env %s for host %s", target, state.host), vim.log.levels.INFO)
  else
    vim.notify(string.format("[pyright_remote] cleared env history for host %s", state.host), vim.log.levels.INFO)
  end
end, { nargs = "?", complete = env_complete })

return M
