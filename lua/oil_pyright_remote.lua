--[[
oil_pyright_remote: start pyright-langserver over SSH and map LSP I/O back to
oil-ssh buffers. Handles remote host/env/root state, remote python/pyright
verification/installation, custom handlers + reconnect logic, and user commands
to switch host/env/root quickly.

重构说明：此文件现在仅作为模块加载入口，主要逻辑已拆分到
lua/oil_pyright_remote/ 目录下的各个子模块中。
--]]

-- 加载核心模块，这会触发所有子模块的初始化
local M = require("oil_pyright_remote.init")

-- 保持向后兼容：直接导出核心模块的所有功能
return M