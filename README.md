# oil-pyright-remote.nvim

Run `pyright-langserver` over SSH and make every LSP interaction work on files opened via `oil-ssh://…`. Tracks remote hosts/virtualenvs/workspace roots, verifies or installs pyright remotely, adapts diagnostics and jumps to oil paths, and auto-reconnects.

## Requirements
- Neovim 0.8+
- SSH access to the target host
- Remote Python virtualenv (pyright will be installed on demand if missing)
- Optional: oil.nvim for `oil-ssh://` buffers

## Installation (lazy.nvim)

```lua
{
  "song54573/oil-pyright-remote.nvim",
  dependencies = { "stevearc/oil.nvim" }, -- required for oil-ssh:// buffers
  lazy = false, -- start as soon as Python buffers open
}
```

The entry file `plugin/oil_pyright_remote.lua` requires `oil_pyright_remote`, so commands/autocmds register automatically.

### Remote prerequisites
- SSH access to the target host (key or agent recommended).
- A Python virtualenv on the remote host; pyright will be installed on demand if missing (see `g:pyright_remote_auto_install`).
- Optional: oil.nvim to open buffers as `oil-ssh://host//path`, enabling seamless path conversion for jumps and diagnostics.

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
| `g:pyright_remote_auto_install` | Install pyright if missing | `false` |
| `g:pyright_remote_start_notify` | Notify on start/reconnect | `false` |
