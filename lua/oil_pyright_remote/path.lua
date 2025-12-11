-- path.lua: 负责 oil-ssh 路径/URI 相关的工具函数
-- 说明：全部函数保持与原始实现一致的核心逻辑，并增加类型校验、错误提示与中文注释，方便阅读与调试。
local M = {}

-----------------------------------------------------------------------
-- 小型工具：统一的字符串校验，减少重复代码，保持 DRY 原则
-----------------------------------------------------------------------
local function ensure_string(val, name, allow_empty)
  if val == nil then
    return nil
  end
  if type(val) ~= "string" then
    error(string.format("%s 必须是字符串，当前类型为 %s", name or "参数", type(val)))
  end
  if not allow_empty and val == "" then
    return nil
  end
  return val
end

-----------------------------------------------------------------------
-- normalize_env(env)
-- 功能：规范化远程 Python 虚拟环境路径，清理空白和常见尾部片段
-- 返回：规范化后的字符串；若为空或无效则返回 nil
-----------------------------------------------------------------------
function M.normalize_env(env)
  local e = ensure_string(env, "env")
  if not e then
    return nil
  end
  -- 去除首尾空白
  e = e:gsub("^%s+", ""):gsub("%s+$", "")
  -- 移除末尾多余的斜杠
  e = e:gsub("/+$", "")
  -- 去掉常见的 /bin/python 或 /bin 结尾，避免后续拼接重复
  e = e:gsub("/bin/python$", ""):gsub("/bin$", "")
  if e == "" then
    return nil
  end
  return e
end

-----------------------------------------------------------------------
-- to_oil_path(fname, host)
-- 功能：将本地/远程文件路径转换为 oil-ssh URL 形式
-- 参数：
--   fname: 目标文件绝对或相对路径
--   host : 远程主机名，必填；若缺失将抛出错误以便早发现配置问题
-- 返回：形如 oil-ssh://<host>//<abs> 或 oil-ssh://<host>/<rel> 的字符串
-----------------------------------------------------------------------
function M.to_oil_path(fname, host)
  local path = ensure_string(fname, "fname")
  if not path then
    error("to_oil_path: fname 不能为空")
  end
  local h = ensure_string(host, "host")
  if not h then
    error("to_oil_path: host 不能为空，请确认已设置远程主机名")
  end

  -- 绝对路径：保持两个斜杠分隔；相对路径：单斜杠
  if path:sub(1, 1) ~= "/" then
    return string.format("oil-ssh://%s/%s", h, path)
  end
  return string.format("oil-ssh://%s//%s", h, path:gsub("^/+", ""))
end

-----------------------------------------------------------------------
-- from_oil_path(name)
-- 功能：从 oil-ssh URL 中提取实际文件系统路径（绝对路径）
-- 返回：形如 /xxx 的路径；若输入不匹配 oil-ssh 协议则返回 nil
-----------------------------------------------------------------------
function M.from_oil_path(name)
  local n = ensure_string(name, "name")
  if not n then
    return nil
  end

  -- 形式一：oil-ssh://host//abs/path
  local _, abs = n:match("^oil%-ssh://([^/]+)//(.+)$")
  if abs then
    return "/" .. abs:gsub("^/+", "")
  end

  -- 形式二：oil-ssh://host/rel/or/abs
  local _, p2 = n:match("^oil%-ssh://([^/]+)/(.*)$")
  if p2 then
    if p2:sub(1, 1) ~= "/" then
      p2 = "/" .. p2
    end
    return p2
  end

  -- 未匹配则返回 nil，方便调用方自行处理
  return nil
end

-----------------------------------------------------------------------
-- location_to_oil_item(loc, host)
-- 功能：将 LSP 的 Location/LocationLink 转为 quickfix/item 结构，并替换为 oil-ssh 路径
-- 参数：
--   loc : LSP 返回的 location 或 locationLink 表
--   host: 远程主机名，可选；缺省时尝试读取全局配置 vim.g.pyright_remote_host
-- 返回：包含 filename/lnum/col/range/uri 的表；若 loc 无效则返回 nil
-----------------------------------------------------------------------
function M.location_to_oil_item(loc, host)
  if type(loc) ~= "table" then
    error("location_to_oil_item: loc 必须是 table")
  end
  local uri = loc.uri or loc.targetUri
  if not uri then
    return nil -- 没有 URI 就无法构建跳转项
  end

  local range = loc.range or loc.targetSelectionRange or loc.targetRange
  local fname = vim.uri_to_fname(uri)
  local oil_path = M.to_oil_path(fname, host or vim.g.pyright_remote_host)

  local line1 = (range and range.start and range.start.line or 0) + 1 -- Neovim 行号从 1 开始
  local col0 = (range and range.start and range.start.character or 0)

  return {
    filename = oil_path,
    lnum = line1,
    col = col0,
    range = range,
    uri = uri,
  }
end

-----------------------------------------------------------------------
-- uri_from_bufnr(bufnr, orig_uri_from_bufnr)
-- 功能：用于替换/包装 Neovim 的 vim.uri_from_bufnr，解决 oil-ssh 缓冲区 URI 解析问题
-- 参数：
--   bufnr                : 目标缓冲区编号
--   orig_uri_from_bufnr  : 可选，原始的 uri_from_bufnr 实现；未提供时回退到 vim.uri_from_bufnr
-- 返回：对应缓冲区的标准 file:// URI；若不是 oil-ssh 缓冲区则直接使用原实现
-----------------------------------------------------------------------
function M.uri_from_bufnr(bufnr, orig_uri_from_bufnr)
  if type(bufnr) ~= "number" then
    error("uri_from_bufnr: bufnr 必须是数字")
  end
  local fallback = orig_uri_from_bufnr or vim.uri_from_bufnr
  if type(fallback) ~= "function" then
    error("uri_from_bufnr: 缺少有效的 fallback 函数")
  end

  local name = vim.api.nvim_buf_get_name(bufnr)
  if type(name) ~= "string" or name == "" then
    return fallback(bufnr)
  end

  -- 匹配 oil-ssh://<host>/<path> 或 oil-ssh://<host>//<abs>
  local host, path = name:match("^oil%-ssh://([^/]+)(/.+)$")
  if host and path then
    if path:sub(1, 2) == "//" then
      path = path:sub(2) -- 消除双斜杠，得到绝对路径
    end
    return vim.uri_from_fname(path)
  end

  -- 非 oil-ssh 场景走原逻辑
  return fallback(bufnr)
end

return M