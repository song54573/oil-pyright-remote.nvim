# Ty Backend 诊断问题调试指南

## 基于深度调研的结论

**重要发现**（来自 Neovim 0.11+ API 和 ty 官方文档调研）：

1. ✅ **配置结构正确**：ty 使用 `settings.ty.*` 接收配置（不是 `init_options`）
2. ✅ **默认诊断模式**：`openFilesOnly`（不是 `workspace`），适合远程 SSH 场景
3. ✅ **Root Markers**：应包含 `ty.toml` 以支持 ty 专用配置
4. ✅ **插件架构**：继续使用 `vim.lsp.start` 手动控制（而非 `vim.lsp.config/enable`）

---

## 问题现象

使用 `uvx ty check xx.py` 可以看到错误，但通过 LSP 插件使用 ty backend 时看不到诊断。

## 快速诊断步骤

### 1. 启用调试模式

在 Neovim 配置中添加：

```lua
-- 启用插件调试日志
vim.g.pyright_remote_debug = true

-- 启用 LSP 详细日志
vim.lsp.set_log_level("debug")
```

重启 Neovim 或重新打开 Python 文件，查看：
- 插件日志（`:messages`）
- LSP 日志（`:LspLog` 或 `~/.cache/nvim/lsp.log`）

### 2. 检查配置传递

打开Python文件后，查看 `:messages`，应该看到类似：

```
[pyright_remote] LSP Config Debug:
  Backend: ty
  Root: /remote/project/path
  Settings: {
    ty = {
      diagnosticMode = "workspace",
      showSyntaxErrors = true
    }
  }
  Init Options: {
    logLevel = "info"
  }
}
```

### 3. 验证 LSP 客户端状态

```vim
:lua print(vim.inspect(vim.lsp.get_clients()))
```

检查：
- ✅ 是否有 `name = "pyright_remote"` 的客户端
- ✅ `config.settings.ty` 是否包含正确配置
- ✅ `config.root_dir` 是否正确（不是 `nil`）

### 4. 检查诊断请求流

在 LSP 日志中搜索（`:LspLog` 后 `/publishDiagnostics`）：

**关键日志模式**：

```
[ DEBUG ] ... "method" = "textDocument/publishDiagnostics"
```

**或者** (Pull 诊断模型):

```
[ DEBUG ] ... "method" = "textDocument/diagnostic"
```

如果**完全找不到**这些日志，说明 ty server 没有发送任何诊断。

---

## 已知问题与解决方案

### 问题 1: Pull vs Push 诊断模型不匹配

**症状**: ty server 启动成功，但没有任何诊断

**原因**: ty 同时支持 pull 和 push 诊断模型。如果 Neovim 使用 pull 模型但没有发送 `textDocument/diagnostic` 请求，就看不到诊断。

**解决方案**:
- 确保使用较新版本的 Neovim (0.10+ 推荐)
- 检查 LSP capabilities 中是否启用了诊断支持

**参考**: [ty Language Server Documentation](https://docs.astral.sh/ty/features/language-server/)

---

### 问题 2: Workspace 诊断被限制

**症状**: 仅在打开的文件中看到部分诊断，`diagnosticMode = "workspace"` 无效

**原因**: 旧版本 ty 存在 "workspace 诊断被 open-files 逻辑限制" 的 bug

**解决方案**:
1. 升级 ty 到最新版本：
   ```bash
   uv tool upgrade ty
   ```

2. 或临时使用 `openFilesOnly` 模式：
   ```lua
   require("oil_pyright_remote").setup({
     backend = "ty",
     lsp_opts = {
       diagnosticMode = "openFilesOnly",  -- 临时方案
     },
   })
   ```

**参考**: [相关修复提交](https://git.joshthomas.dev/language-servers/ruff/commits/commit/88de5727dfab24ce223024de683b283b70ef62e7)

---

### 问题 3: Root Directory 检测失败

**症状**: LSP 日志显示 `root_dir = nil` 或诊断不显示

**原因**: ty 需要检测到项目根目录才能提供完整诊断。默认检测标记：
- `ty.toml`
- `pyproject.toml`
- `setup.py`
- `setup.cfg`
- `requirements.txt`
- `.git/`

**解决方案**:
1. 确保项目包含至少一个 root marker
2. 或手动指定 root:
   ```lua
   require("oil_pyright_remote").setup({
     backend = "ty",
     root = "/remote/project/path",  -- 显式指定
   })
   ```

**参考**: [nvim-lspconfig ty 配置](https://git.sudomsg.com/mirror/nvim-lspconfig/about/doc/configs.md)

---

### 问题 4: VIRTUAL_ENV 环境变量不匹配

**症状**: `uvx ty check` 可以看到错误，但 LSP 看不到

**原因**: ty 通过 `VIRTUAL_ENV` 环境变量定位依赖。插件设置的环境可能与命令行不一致。

**诊断**:
```bash
# 查看 uvx 使用的环境
uvx ty --version

# 查看插件设置的环境
# 在 Neovim 中:
:lua print(require("oil_pyright_remote.config").get("env"))
```

**解决方案**:
确保配置的 `env` 路径与 `uvx` 使用的环境一致。

**参考**: [ty Environment Variables](https://docs.astral.sh/ty/reference/environment/)

---

## 配置检查清单

- [ ] **Backend 设置正确**: `backend = "ty"`
- [ ] **Settings 结构正确**: `settings.ty.*` (不是 `init_options`)
- [ ] **Root directory 可检测**: 项目包含 `pyproject.toml` 或其他 marker
- [ ] **Ty 版本最新**: 运行 `uv tool upgrade ty`
- [ ] **LSP 日志启用**: `vim.lsp.set_log_level("debug")`
- [ ] **诊断模式明确**: `diagnosticMode = "workspace"` 或 `"openFilesOnly"`
- [ ] **语法错误启用**: `showSyntaxErrors = true`

---

## 对比测试：排除插件问题

创建最小化配置测试 ty 是否正常工作：

```lua
-- ~/.config/nvim/lua/test_ty.lua
vim.lsp.set_log_level("debug")

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'python',
  callback = function()
    vim.lsp.start({
      name = 'ty_test',
      cmd = { 'ty', 'server' },  -- 或使用绝对路径
      root_dir = vim.fn.getcwd(),
      settings = {
        ty = {
          diagnosticMode = 'workspace',
          showSyntaxErrors = true,
        },
      },
      init_options = {
        logLevel = 'debug',
      },
    })
  end,
})
```

使用：
```vim
:luafile ~/.config/nvim/lua/test_ty.lua
:edit test.py
```

如果这个配置能看到诊断，说明问题在插件的远程 SSH 传输上。

---

## 常用调试命令

```vim
" 查看所有 LSP 客户端
:lua print(vim.inspect(vim.lsp.get_clients()))

" 查看当前文件的诊断
:lua print(vim.inspect(vim.diagnostic.get(0)))

" 重启 LSP
:LspRestart

" 查看 LSP 日志
:LspLog

" 查看插件日志
:messages

" 清空消息
:messages clear

" 手动触发诊断刷新 (如果支持)
:lua vim.lsp.buf.document_diagnostic()
```

---

## 报告 Bug 时需提供的信息

如果以上步骤都无法解决问题，请提供：

1. **完整的插件调试日志**（启用 `vim.g.pyright_remote_debug = true`）
2. **LSP 日志片段**（包含 `textDocument/publishDiagnostics` 或 `textDocument/diagnostic`）
3. **Ty 版本**：
   ```bash
   uvx ty --version
   ```
4. **Neovim 版本**：
   ```vim
   :version
   ```
5. **最小复现案例**：
   - Python 文件内容（包含语法错误）
   - 完整配置

---

## 相关资源

- [ty 官方文档](https://docs.astral.sh/ty/)
- [ty Editor Settings](https://docs.astral.sh/ty/reference/editor-settings/)
- [ty Language Server](https://docs.astral.sh/ty/features/language-server/)
- [nvim-lspconfig ty 配置](https://git.sudomsg.com/mirror/nvim-lspconfig/about/doc/configs.md)
- [Neovim LSP 文档](https://neovim.io/doc/user/lsp.html)
