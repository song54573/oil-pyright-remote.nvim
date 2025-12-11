-- ssh_runner.lua: SSH 命令执行模块
-- 功能：封装所有远程 SSH 命令的构造和执行逻辑
-- 设计原则：安全的命令构造、统一的异步执行、清晰的错误处理

local M = {}

-- 依赖模块
local config = require("oil_pyright_remote.config")
local state = require("oil_pyright_remote.state")

-----------------------------------------------------------------------
-- M.remote_bash(script)
-- 功能：构造远程 bash 执行命令
-- 参数：script - 要在远程执行的 shell 脚本
-- 返回：适合 vim.fn.jobstart 的命令表
function M.remote_bash(script)
  local host = config.get("host")
  if not host or host == "" then
    error("remote_bash: 主机名未设置")
  end

  if type(script) ~= "string" or script == "" then
    error("remote_bash: script 必须是非空字符串")
  end

  return { "ssh", host, script }
end

-----------------------------------------------------------------------
-- M.run_async(cmd, cb, opts)
-- 功能：异步执行命令
-- 参数：
--   cmd  - 命令表（如 {"ssh", "host", "script"}）
--   cb   - 回调函数 cb(success, stdout, code, signal, stderr)
--   opts - 可选配置表：
--          timeout: 超时毫秒数，默认300000（5分钟）
--          quiet:   是否静默执行，默认false
-- 返回：job ID 或 nil（失败时）
function M.run_async(cmd, cb, opts)
  opts = opts or {}
  local timeout = opts.timeout or 300000
  local quiet = opts.quiet == true

  if type(cmd) ~= "table" or #cmd == 0 then
    error("run_async: cmd 必须是非空表")
  end

  if type(cb) ~= "function" then
    error("run_async: cb 必须是函数")
  end

  local stdout, stderr = {}, {}
  local job_timer = nil
  local job_id = nil

  -- 超时处理
  local function start_timeout_timer()
    if timeout <= 0 then
      return
    end

    job_timer = vim.loop.new_timer()
    if job_timer then
      job_timer:start(timeout, 0, function()
        if job_id then
          vim.fn.jobstop(job_id)
          vim.schedule(function()
            if not quiet then
              vim.notify(string.format("[ssh_runner] 命令执行超时 (%.1fs)", timeout / 1000), vim.log.levels.WARN)
            end
            cb(false, stdout, -1, 0, { "timeout" })
          end)
        end
        if job_timer then
          job_timer:close()
          job_timer = nil
        end
      end)
    end
  end

  -- 清理资源
  local function cleanup()
    if job_timer then
      job_timer:close()
      job_timer = nil
    end
  end

  job_id = vim.fn.jobstart(cmd, {
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
      cleanup()
      local success = code == 0
      cb(success, stdout, code, signal, stderr)
    end,
  })

  if job_id <= 0 then
    cleanup()
    local error_msg = { "jobstart failed: " .. tostring(job_id) }
    cb(false, {}, 1, 0, error_msg)
    return nil
  end

  start_timeout_timer()
  return job_id
end

-----------------------------------------------------------------------
-- M.python_exists_async(path, cb)
-- 功能：异步检查远程 python 是否存在且可执行
-- 参数：
--   path - python 路径（如 "/path/to/venv/bin/python"）
--   cb   - 回调函数 cb(exists, output, code)
function M.python_exists_async(path, cb)
  if type(path) ~= "string" or path == "" then
    cb(false, { "empty path" }, 1)
    return
  end

  if type(cb) ~= "function" then
    error("python_exists_async: cb 必须是函数")
  end

  -- 第一步：检查文件是否可执行
  local cmd1 = M.remote_bash(string.format([[test -x "%s"]], path))
  M.run_async(cmd1, function(ok, out, code, signal)
    if ok then
      cb(true, out, code, signal)
      return
    end

    -- 第二步：尝试执行 -V 获取版本信息
    local cmd2 = M.remote_bash(string.format([["%s" -V]], path))
    M.run_async(cmd2, function(ok2, out2, code2, signal2)
      local merged = {}
      vim.list_extend(merged, out or {})
      vim.list_extend(merged, out2 or {})
      cb(ok2, merged, code2 ~= 0 and code2 or code)
    end, { timeout = 10000 }) -- python -V 通常很快，10秒超时
  end, { timeout = 5000 }) -- test -x 应该很快，5秒超时
end

-----------------------------------------------------------------------
-- M.build_pyright_cmd()
-- 功能：构建启动 pyright-langserver 的 SSH 命令
-- 返回：适合 vim.fn.jobstart 的命令表
function M.build_pyright_cmd()
  local env = config.get("env")
  local host = config.get("host")

  if not host or host == "" then
    error("build_pyright_cmd: 主机名未设置")
  end

  if not env or env == "" then
    error("build_pyright_cmd: 虚拟环境路径未设置")
  end

  local env_bin = string.format("%s/bin", env)
  local pyright_bin = string.format([[%s/pyright-langserver]], env_bin)
  local py_bin = string.format([[%s/python]], env_bin)

  -- 构建远程执行的 shell 脚本
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

  return { "ssh", host, cmd_str }
end

-----------------------------------------------------------------------
-- M.execute_remote_script(script, cb, opts)
-- 功能：便捷函数：执行远程脚本
-- 参数：
--   script - 要执行的脚本内容
--   cb     - 回调函数 (可选)
--   opts   - 选项 (可选)
-- 返回：job ID 或 nil
function M.execute_remote_script(script, cb, opts)
  local cmd = M.remote_bash(script)
  return M.run_async(cmd, cb or function() end, opts)
end

-----------------------------------------------------------------------
-- M.test_connection(cb)
-- 功能：测试 SSH 连接是否可用
-- 参数：cb - 回调函数 cb(success, output)
function M.test_connection(cb)
  if type(cb) ~= "function" then
    error("test_connection: cb 必须是函数")
  end

  local host = config.get("host")
  if not host or host == "" then
    cb(false, { "主机名未设置" })
    return
  end

  -- 使用简单的 true 命令测试连接
  local cmd = { "ssh", host, "true" }
  M.run_async(cmd, function(success, output, code)
    if success then
      cb(true, { "连接成功" })
    else
      cb(false, vim.list_extend(output or {}, { string.format("退出码: %d", code) }))
    end
  end, { timeout = 10000, quiet = true })
end

-----------------------------------------------------------------------
-- M.get_remote_python_version(cb)
-- 功能：获取远程 python 版本信息
-- 参数：cb - 回调函数 cb(success, version_info)
function M.get_remote_python_version(cb)
  if type(cb) ~= "function" then
    error("get_remote_python_version: cb 必须是函数")
  end

  local env = config.get("env")
  if not env or env == "" then
    cb(false, "虚拟环境未设置")
    return
  end

  local py_bin = env .. "/bin/python"
  local script = string.format([["%s" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"]], py_bin)

  M.execute_remote_script(script, function(success, output)
    if success and output and #output > 0 then
      local version = output[1]:match("%d+%.%d+%.%d+")
      cb(true, version or "unknown")
    else
      cb(false, table.concat(output or {}, "\n"))
    end
  end, { timeout = 15000 })
end

-----------------------------------------------------------------------
-- M.cleanup()
-- 功能：清理资源（如果有的话）
function M.cleanup()
  -- 当前实现没有需要清理的全局资源
  -- 保留此接口以备将来扩展
end

return M