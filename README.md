# oil-pyright-remote.nvim

Run `pyright-langserver` or `ty` over SSH and make every LSP interaction work on files opened via `oil-ssh://…`. Tracks remote hosts/virtualenvs/workspace roots, verifies or installs LSP backends remotely, adapts diagnostics and jumps to oil paths, and auto-reconnects.

## Requirements
- Neovim 0.8+
- SSH access to the target host
- Remote Python virtualenv (pyright or ty will be installed on demand if missing)
- Optional: oil.nvim for `oil-ssh://` buffers

## Installation (lazy.nvim)

```lua
{
  "song54573/oil-pyright-remote.nvim",
  dependencies = { "stevearc/oil.nvim" }, -- required for oil-ssh:// buffers
  lazy = false, -- start as soon as Python buffers open
  config = function()
    require("oil_pyright_remote").setup({})
  end,
}
```

The entry file `plugin/oil_pyright_remote.lua` only loads the module early.
Commands, autocmds, and diagnostics handlers are registered by calling
`require("oil_pyright_remote").setup({...})`.

On Neovim 0.11 and 0.12, the plugin registers a native `vim.lsp.config()`
definition for `pyright_remote`, keeps the existing remote preflight checks in
front of client startup, and avoids reusing or stopping clients that are
already shutting down.

The plugin may restart the remote client internally during root correction or
reconnect handling. You do not need to run `:PyrightRemoteRestart` manually for
client stop/start transitions to happen.

The plugin does not call `vim.lsp.enable('pyright_remote')` internally. Native
configs are registered for compatibility with Neovim's 0.11/0.12 LSP APIs,
while actual remote client lifecycle remains plugin-managed so SSH preflight
checks stay in front of startup.

### Remote prerequisites
- SSH access to the target host (key or agent recommended).
- A Python virtualenv on the remote host; pyright or ty will be installed on demand if missing (see `g:pyright_remote_auto_install`).
- Optional: oil.nvim to open buffers as `oil-ssh://host//path`, enabling seamless path conversion for jumps and diagnostics.

## Backend Support

This plugin supports two Python LSP backends:

- **pyright** (default): The standard Python type checker from Microsoft
- **ty**: A fast Rust-based Python type checker from Astral (creators of Ruff and uv)

To switch backends, set `g:pyright_remote_backend` or use the `backend` option in `setup()`.

## Commands
- `:PyrightRemoteHost [host]` — set/show remote host (completes from `~/.ssh/config`).
- `:PyrightRemoteEnv [env_dir]` — set/show remote virtualenv root; remembers history and lets you pick interactively.
- `:PyrightRemoteRoot [path]` — pin workspace root (remote path). Default: directory of current file.
- `:PyrightRemoteRestart` — restart the oil_pyright_remote client for the current buffer.
- `:PyrightRemoteEnvForget [env_dir]` — forget one or all remembered environments.

Pyright is started automatically on `FileType python`. If startup fails, prompts will guide you to re-enter host/env/python paths.

## Configuration (globals or environment)

| Variable | Purpose | Default |
| --- | --- | --- |
| `g:pyright_remote_host` / `PYRIGHT_REMOTE_HOST` | SSH host | none |
| `g:pyright_remote_env` / `PYRIGHT_REMOTE_ENV` | Remote virtualenv root | none |
| `g:pyright_remote_workspace_root` / `PYRIGHT_REMOTE_ROOT` | Fixed workspace root | auto-detected |
| `g:pyright_remote_backend` | LSP backend: `"pyright"` or `"ty"` | `"pyright"` |
| `g:pyright_remote_auto_install` | Install LSP backend if missing | `false` |
| `g:pyright_remote_start_notify` | Notify on start/reconnect | `false` |
| `g:pyright_remote_auto_prompt` | Auto-prompt for environment path | `true` |

### Example: Using ty backend

```lua
require("oil_pyright_remote").setup({
  backend = "ty",
  auto_install = true,
})
```

Or via global variable:
```vim
let g:pyright_remote_backend = 'ty'
```
