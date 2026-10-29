local M = {}

-- User-owned only: project configuration cannot register executables or grant trust.
function M.path()
  return vim.fn.stdpath("data") .. "/sia/mcp.json"
end

function M.load()
  local path = M.path()
  if vim.fn.filereadable(path) == 0 then
    return { servers = {}, trust = {} }
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  assert(ok and type(data) == "table", "Invalid MCP registry: " .. path)
  data.servers = data.servers or {}
  data.trust = data.trust or {}
  assert(
    type(data.servers) == "table" and type(data.trust) == "table",
    "Invalid MCP registry: " .. path
  )
  for name, trusted in pairs(data.trust) do
    assert(
      type(name) == "string" and type(trusted) == "boolean",
      "Invalid MCP trust entry"
    )
  end
  return data
end

function M.save(data)
  local path = M.path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p", "0700")
  local tmp = path .. ".tmp"
  assert(
    vim.fn.writefile({ vim.json.encode(data) }, tmp) == 0,
    "Could not write MCP registry"
  )
  vim.fn.setfperm(tmp, "rw-------")
  local ok, err = vim.uv.fs_rename(tmp, path)
  assert(ok, err)
end

return M
