local M = {}

local usage =
  "Usage: SiaMcp[!] add <server> -- <command> [args...] | remove <server> | trust <server> | untrust <server> | status | enable <server> | disable <server> | stop <server> | restart <server>"

local function select_server(action, name, silent)
  local config = require("sia.config")
  local updated, err = config.update_auto_config(function(json)
    local names = json.mcp or {}
    if action == "enable" then
      if not vim.tbl_contains(names, name) then
        names[#names + 1] = name
      end
    else
      names = vim.tbl_filter(function(value)
        return value ~= name
      end, names)
    end
    json.mcp = names
  end)
  assert(updated, err)
  local lc = config.get_local_config()
  local enabled = vim.tbl_contains(lc and lc.mcp or {}, name)
  if not silent then
    vim.notify("sia: " .. name .. (enabled and " enabled" or " disabled"))
  end
end

local function run(args)
  local registry = require("sia.mcp.registry")
  local action, name = args.fargs[1] or "status", args.fargs[2]
  if action == "status" then
    vim.notify(vim.inspect(registry.status()))
    return
  end
  if action == "add" then
    assert(
      name and #name <= 64 and name:match("^[%w_-]+$"),
      "Invalid MCP server identity"
    )
    assert(args.fargs[3] == "--" and args.fargs[4] and args.fargs[4] ~= "", usage)
    assert(not registry.servers[name], "MCP server already registered: " .. name)
    local command = vim.list_slice(args.fargs, 4)
    for _, arg in ipairs(command) do
      assert(not arg:find("\0", 1, true), "Invalid MCP argv")
    end
    if command[1]:find("/", 1, true) then
      command[1] = vim.fn.fnamemodify(vim.fn.expand(command[1]), ":p")
    end
    local store = require("sia.mcp.store")
    local stored = store.load()
    stored.servers[name] = { command = command, cwd = vim.fn.getcwd() }
    store.save(stored)
    registry.configure(registry.options or {})
    vim.notify("sia: " .. name .. " added")
    if args.bang then
      select_server("enable", name, true)
    end
    return
  end
  if action == "remove" then
    assert(name, usage)
    local configured = (registry.options or {}).servers or {}
    assert(not configured[name], "Remove " .. name .. " from setup()")
    local store = require("sia.mcp.store")
    local stored = store.load()
    assert(stored.servers[name], "Unknown persisted MCP server: " .. name)
    stored.servers[name] = nil
    stored.trust[name] = nil
    store.save(stored)
    registry.configure(registry.options or {})
    select_server("disable", name, true)
    vim.notify("sia: " .. name .. " removed")
    return
  end
  if action == "restart" then
    registry.configure(registry.options or {})
  end
  assert(name and registry.servers[name], "Unknown MCP server: " .. tostring(name))
  if action == "trust" or action == "untrust" then
    local trusted = action == "trust"
    local configured = (registry.options or {}).servers or {}
    assert(
      not configured[name] or configured[name].trust == nil,
      "Change trust for " .. name .. " in setup()"
    )
    local store = require("sia.mcp.store")
    local stored = store.load()
    stored.trust[name] = trusted
    -- A persisted definition may itself have an explicit trust value.
    if stored.servers[name] then
      stored.servers[name].trust = nil
    end
    store.save(stored)
    registry.configure(registry.options or {})
    vim.notify("sia: " .. name .. (trusted and " trusted" or " untrusted"))
  elseif action == "enable" or action == "disable" then
    select_server(action, name)
  elseif action == "stop" or action == "restart" then
    registry.stop(name)
    if action == "restart" then
      registry.ensure(name, function(err)
        vim.notify(
          "sia: " .. (err or (name .. " ready")),
          err and vim.log.levels.ERROR or vim.log.levels.INFO
        )
      end)
    end
  else
    error(usage)
  end
end

function M.run(args)
  local ok, err = pcall(run, args)
  if not ok then
    vim.notify("sia: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.complete(lead, line)
  local action = line:match("SiaMcp!?%s+(%w+)%s+")
  local choices = action and vim.tbl_keys(require("sia.mcp.registry").servers)
    or {
      "status",
      "add",
      "remove",
      "trust",
      "untrust",
      "enable",
      "disable",
      "stop",
      "restart",
    }
  if action == "add" then
    return {}
  end
  table.sort(choices)
  return vim.tbl_filter(function(item)
    return vim.startswith(item, lead)
  end, choices)
end

return M
