describe("oil_pyright_remote", function()
  local function reset_modules()
    package.loaded["oil_pyright_remote"] = nil
    package.loaded["oil_pyright_remote.config"] = nil
    package.loaded["oil_pyright_remote.diagnostics"] = nil
    package.loaded["oil_pyright_remote.installer"] = nil
    package.loaded["oil_pyright_remote.lsp"] = nil
    package.loaded["oil_pyright_remote.ssh_runner"] = nil
    package.loaded["oil_pyright_remote.state"] = nil
    package.loaded["oil_pyright_remote.ui"] = nil
  end

  before_each(function()
    vim.g.pyright_remote_host = nil
    vim.g.pyright_remote_env = nil
    vim.g.pyright_remote_workspace_root = nil
    vim.g.pyright_remote_backend = nil
    vim.g.pyright_remote_auto_install = nil
    vim.g.pyright_remote_start_notify = nil
    vim.g.pyright_remote_auto_prompt = nil
    reset_modules()
  end)

  local function with_stubbed_native_lsp(run)
    local original_config = vim.lsp.config
    local original_enable = vim.lsp.enable
    local original_is_enabled = vim.lsp.is_enabled
    local original_create_autocmd = vim.api.nvim_create_autocmd
    local original_schedule = vim.schedule
    local enabled = {}
    local config_store = setmetatable({}, {
      __call = function(self, name, cfg)
        self[name] = cfg
      end,
    })

    vim.lsp.config = config_store
    vim.lsp.enable = function(name)
      table.insert(enabled, name)
    end
    vim.lsp.is_enabled = function()
      return false
    end
    vim.api.nvim_create_autocmd = function()
      return 1
    end
    vim.schedule = function()
    end

    local ok, result = pcall(run, config_store, enabled)

    vim.lsp.config = original_config
    vim.lsp.enable = original_enable
    vim.lsp.is_enabled = original_is_enabled
    vim.api.nvim_create_autocmd = original_create_autocmd
    vim.schedule = original_schedule

    assert.is_true(ok, result)
  end

  it("loads without error and registers commands", function()
    local ok, err = pcall(require, "oil_pyright_remote")
    assert.is_true(ok, err or "module should load")
    local original_create_autocmd = vim.api.nvim_create_autocmd
    local original_schedule = vim.schedule
    vim.api.nvim_create_autocmd = function()
      return 1
    end
    vim.schedule = function()
    end

    require("oil_pyright_remote").setup({})

    vim.api.nvim_create_autocmd = original_create_autocmd
    vim.schedule = original_schedule

    local cmds = vim.api.nvim_get_commands({ builtin = false })
    local expected = {
      "PyrightRemoteHost",
      "PyrightRemoteEnv",
      "PyrightRemoteRoot",
      "PyrightRemoteRestart",
      "PyrightRemoteEnvForget",
    }
    for _, name in ipairs(expected) do
      assert.truthy(cmds[name], ("command %s should exist"):format(name))
    end
  end)

  it("loads auto_prompt from vim.g", function()
    vim.g.pyright_remote_auto_prompt = false
    local config = require("oil_pyright_remote.config")
    config.reload()

    assert.is_false(config.get("auto_prompt"))
  end)

  it("uses vim.diagnostic.jump when available", function()
    local diagnostics = require("oil_pyright_remote.diagnostics")
    local original_jump = vim.diagnostic.jump
    local original_next = vim.diagnostic.goto_next
    local called = nil

    vim.diagnostic.jump = function(opts)
      called = opts.count
    end
    vim.diagnostic.goto_next = function()
      error("goto_next should not be called when jump exists")
    end

    diagnostics.goto_next_diagnostic()

    vim.diagnostic.jump = original_jump
    vim.diagnostic.goto_next = original_next
    assert.are.equal(1, called)
  end)

  it("falls back to legacy diagnostic jump api", function()
    local diagnostics = require("oil_pyright_remote.diagnostics")
    local original_jump = vim.diagnostic.jump
    local original_prev = vim.diagnostic.goto_prev
    local called = false

    vim.diagnostic.jump = nil
    vim.diagnostic.goto_prev = function()
      called = true
    end

    diagnostics.goto_prev_diagnostic()

    vim.diagnostic.jump = original_jump
    vim.diagnostic.goto_prev = original_prev
    assert.is_true(called)
  end)

  it("prefers client:stop over vim.lsp.stop_client", function()
    local lsp = require("oil_pyright_remote.lsp")
    local stopped = nil
    local original_stop_client = vim.lsp.stop_client

    vim.lsp.stop_client = function()
      error("vim.lsp.stop_client should not be called when client:stop exists")
    end

    local ok = lsp._compat.stop_lsp_client({
      id = 42,
      stop = function(_, force)
        stopped = force
      end,
    }, true)

    vim.lsp.stop_client = original_stop_client
    assert.is_true(ok)
    assert.is_true(stopped)
  end)

  it("falls back to vim.lsp.stop_client when client:stop is unavailable", function()
    local lsp = require("oil_pyright_remote.lsp")
    local original_stop_client = vim.lsp.stop_client
    local called_id, called_force = nil, nil

    vim.lsp.stop_client = function(client_id, force)
      called_id = client_id
      called_force = force
    end

    local ok = lsp._compat.stop_lsp_client({ id = 9 }, false)

    vim.lsp.stop_client = original_stop_client
    assert.is_true(ok)
    assert.are.equal(9, called_id)
    assert.is_false(called_force)
  end)

  it("registers and enables native config on Neovim 0.11+", function()
    with_stubbed_native_lsp(function(config_store, enabled)
      local lsp = require("oil_pyright_remote.lsp")
      lsp.setup()

      assert.truthy(config_store.pyright_remote)
      assert.are.same({ "pyright_remote" }, enabled)
      assert.is_true(lsp._compat.is_native_mode())
      assert.are.equal("function", type(config_store.pyright_remote.root_dir))
    end)
  end)

  it("native root_dir respects ready state and refreshes dynamic config", function()
    with_stubbed_native_lsp(function(config_store, _)
      local config = require("oil_pyright_remote.config")
      config.set({
        host = "demo-host",
        env = "/tmp/demo-env",
        root = "/remote/project",
      })

      local lsp = require("oil_pyright_remote.lsp")
      lsp.setup()

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, "oil-ssh://demo-host//remote/project/main.py")
      vim.bo[bufnr].filetype = "python"

      local root_dir = nil
      config_store.pyright_remote.root_dir(bufnr, function(dir)
        root_dir = dir
      end)
      assert.is_nil(root_dir)

      lsp._compat.mark_buf_ready(bufnr)
      config_store.pyright_remote.root_dir(bufnr, function(dir)
        root_dir = dir
      end)

      assert.are.equal("/remote/project", root_dir)
      assert.are.equal("demo-host", config_store.pyright_remote._pyright_remote_host)
      assert.are.same({ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=3", "-o", "TCPKeepAlive=yes", "demo-host" }, vim.list_slice(config_store.pyright_remote.cmd, 1, 12))
      assert.are.equal("/remote/project", config_store.pyright_remote.workspace_folders[1].name)
    end)
  end)

  it("native and legacy runtime configs stay consistent", function()
    with_stubbed_native_lsp(function(_, _)
      local config = require("oil_pyright_remote.config")
      config.set({
        host = "demo-host",
        env = "/tmp/demo-env",
        root = "/remote/project",
      })

      local lsp = require("oil_pyright_remote.lsp")
      lsp.setup()

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, "oil-ssh://demo-host//remote/project/legacy-main.py")
      vim.bo[bufnr].filetype = "python"

      local runtime = lsp._compat.build_runtime_for_buf(bufnr, lsp.get_default_config())
      local legacy = lsp.build_config(bufnr)
      local native_cfg = lsp._compat.build_native_client_config(bufnr, runtime)

      assert.are.same(legacy.cmd, native_cfg.cmd)
      assert.are.same(legacy.settings, native_cfg.settings)
      assert.are.same(legacy.init_options, native_cfg.init_options)
      assert.are.equal(legacy.root_dir, native_cfg.root_dir)
      assert.are.same(legacy.workspace_folders, native_cfg.workspace_folders)
      assert.are.equal(legacy._pyright_remote_host, native_cfg._pyright_remote_host)
    end)
  end)

  it("reuses cached runtime snapshots for identical host env and root", function()
    local config = require("oil_pyright_remote.config")
    config.set({
      host = "demo-host",
      env = "/tmp/demo-env",
      root = "/remote/project",
    })

    local lsp = require("oil_pyright_remote.lsp")
    local ssh_runner = require("oil_pyright_remote.ssh_runner")
    local original_build_pyright_cmd = ssh_runner.build_pyright_cmd
    local build_count = 0

    ssh_runner.build_pyright_cmd = function()
      build_count = build_count + 1
      return { "ssh", "demo-host", "pyright-langserver", "--stdio" }
    end

    local buf1 = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf1, "oil-ssh://demo-host//remote/project/a.py")
    vim.bo[buf1].filetype = "python"

    local buf2 = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf2, "oil-ssh://demo-host//remote/project/b.py")
    vim.bo[buf2].filetype = "python"

    local runtime1 = lsp._compat.build_runtime_for_buf(buf1, lsp.get_default_config())
    local runtime2 = lsp._compat.build_runtime_for_buf(buf2, lsp.get_default_config())

    ssh_runner.build_pyright_cmd = original_build_pyright_cmd

    assert.are.equal(1, build_count)
    assert.is_true(runtime1.backend_config == runtime2.backend_config)
    assert.is_true(runtime1.workspace_folders == runtime2.workspace_folders)
  end)

  it("deduplicates async remote root probes and fan-outs the result", function()
    local config = require("oil_pyright_remote.config")
    config.set({
      host = "demo-host",
      env = "/tmp/demo-env",
    })

    local lsp = require("oil_pyright_remote.lsp")
    local ssh_runner = require("oil_pyright_remote.ssh_runner")
    local original_execute_remote_script = ssh_runner.execute_remote_script
    local run_count = 0
    local pending_cb = nil

    ssh_runner.execute_remote_script = function(_, cb)
      run_count = run_count + 1
      pending_cb = cb
      return 1
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "oil-ssh://demo-host//remote/project/pkg/main.py")
    vim.bo[bufnr].filetype = "python"

    local root_info = lsp._compat.get_root_resolution_for_buf(bufnr, lsp.get_default_config())
    local results = {}
    lsp._compat.request_remote_root_probe(root_info, function(root)
      table.insert(results, root)
    end)
    lsp._compat.request_remote_root_probe(root_info, function(root)
      table.insert(results, root)
    end)

    pending_cb(true, { "/remote/project" })
    ssh_runner.execute_remote_script = original_execute_remote_script

    assert.are.equal(1, run_count)
    assert.are.same({ "/remote/project", "/remote/project" }, results)
  end)

  it("corrects provisional roots only once per resolved project root", function()
    local config = require("oil_pyright_remote.config")
    config.set({
      host = "demo-host",
      env = "/tmp/demo-env",
    })

    local lsp = require("oil_pyright_remote.lsp")
    local ssh_runner = require("oil_pyright_remote.ssh_runner")
    local original_execute_remote_script = ssh_runner.execute_remote_script
    local original_get_clients = lsp.get_clients
    local original_kick_existing_python = lsp.kick_existing_python
    local original_schedule = vim.schedule
    local kick_count = 0
    local stop_count = 0
    local pending_cb = nil

    ssh_runner.execute_remote_script = function(_, cb)
      pending_cb = cb
      return 1
    end
    vim.schedule = function(fn)
      fn()
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "oil-ssh://demo-host//remote/project/pkg/root-fix-main.py")
    vim.bo[bufnr].filetype = "python"

    local client = {
      id = 7,
      config = { root_dir = "/remote/project/pkg" },
      stop = function()
        stop_count = stop_count + 1
      end,
    }

    lsp.get_clients = function(opts)
      if opts and opts.bufnr == bufnr then
        return { client }
      end
      return { client }
    end
    lsp.kick_existing_python = function()
      kick_count = kick_count + 1
    end

    local runtime = {
      backend = "pyright",
      host = "demo-host",
      env = "/tmp/demo-env",
      root_dir = "/remote/project/pkg",
      root_info = lsp._compat.get_root_resolution_for_buf(bufnr, lsp.get_default_config()),
    }

    lsp._compat.ensure_root_resolution_for_runtime(bufnr, runtime)
    lsp._compat.ensure_root_resolution_for_runtime(bufnr, runtime)

    pending_cb(true, { "/remote/project" })

    ssh_runner.execute_remote_script = original_execute_remote_script
    lsp.get_clients = original_get_clients
    lsp.kick_existing_python = original_kick_existing_python
    vim.schedule = original_schedule

    assert.are.equal(1, stop_count)
    assert.are.equal(1, kick_count)
  end)

  it("uses a custom hover request handler with a stronger float border", function()
    local lsp = require("oil_pyright_remote.lsp")
    local original_buf_request = vim.lsp.buf_request
    local original_make_position_params = vim.lsp.util.make_position_params
    local original_hover = vim.lsp.buf.hover
    local original_handler = vim.lsp.handlers.hover
    local original_get_option_value = vim.api.nvim_get_option_value
    local original_set_option_value = vim.api.nvim_set_option_value
    local original_win_is_valid = vim.api.nvim_win_is_valid
    local original_get_clients = lsp.get_clients
    local received = {}

    vim.lsp.buf_request = function(bufnr, method, params, handler)
      received.bufnr = bufnr
      received.method = method
      received.params = params
      received.handler = handler
    end
    vim.lsp.util.make_position_params = function()
      return { textDocument = { uri = "file:///tmp/demo.py" } }
    end
    vim.lsp.buf.hover = function()
      error("fallback hover should not be used when remote client exists")
    end
    vim.lsp.handlers.hover = function(_, _, _, opts)
      received.config = opts
      return 21, 42
    end
    vim.api.nvim_win_is_valid = function(winid)
      return winid == 42
    end
    vim.api.nvim_get_option_value = function(_, _)
      return ""
    end
    vim.api.nvim_set_option_value = function(_, value, _)
      received.winhighlight = value
    end
    lsp.get_clients = function()
      return { { id = 1, offset_encoding = "utf-16" } }
    end

    local bufnr = vim.api.nvim_create_buf(false, true)
    lsp.hover(bufnr)
    received.handler(nil, { contents = "demo" }, { method = "textDocument/hover", bufnr = bufnr }, nil)

    vim.lsp.buf_request = original_buf_request
    vim.lsp.util.make_position_params = original_make_position_params
    vim.lsp.buf.hover = original_hover
    vim.lsp.handlers.hover = original_handler
    vim.api.nvim_get_option_value = original_get_option_value
    vim.api.nvim_set_option_value = original_set_option_value
    vim.api.nvim_win_is_valid = original_win_is_valid
    lsp.get_clients = original_get_clients

    assert.are.equal(bufnr, received.bufnr)
    assert.are.equal("textDocument/hover", received.method)
    assert.are.equal("single", received.config.border)
    assert.are.equal("FloatBorder:DiagnosticInfo", received.winhighlight)
  end)
end)
