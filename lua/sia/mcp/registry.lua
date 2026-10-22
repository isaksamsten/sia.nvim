local M = { servers = {} }

local function positive(value, default, max)
  value = value or default
  assert(
    type(value) == "number" and value > 0 and value <= max and value % 1 == 0,
    "Invalid MCP limit"
  )
  return value
end

function M.configure(options)
  assert(
    type(options) == "table" and type(options.servers or {}) == "table",
    "mcp.servers must be a table"
  )
  assert(
    vim.tbl_count(options.servers or {}) <= 16,
    "At most 16 trusted MCP servers are supported"
  )
  local configs = {}
  for name, raw in pairs(options.servers or {}) do
    assert(
      type(name) == "string" and #name <= 64 and name:match("^[%w_-]+$"),
      "Invalid MCP server identity"
    )
    assert(type(raw) == "table", "Invalid MCP server configuration")
    local c = vim.deepcopy(raw)
    assert(
      type(c.command) == "table" and vim.islist(c.command) and #c.command > 0,
      "MCP command must be argv"
    )
    for _, arg in ipairs(c.command) do
      assert(type(arg) == "string" and not arg:find("\0", 1, true), "Invalid MCP argv")
    end
    assert(c.command[1] ~= "", "Empty MCP executable")
    if c.command[1]:find("/", 1, true) then
      c.command[1] = vim.fn.fnamemodify(vim.fn.expand(c.command[1]), ":p")
    end
    assert(
      type(c.tools) == "table" and vim.islist(c.tools) and #c.tools > 0,
      "MCP requires a nonempty tool allowlist"
    )
    for _, tool in ipairs(c.tools) do
      assert(type(tool) == "string" and tool ~= "", "Invalid MCP tool allowlist")
    end
    assert(c.cwd == nil or type(c.cwd) == "string", "Invalid MCP cwd")
    c.cwd = vim.fn.fnamemodify(vim.fn.expand(c.cwd or vim.fn.getcwd()), ":p")
    assert(vim.fn.isdirectory(c.cwd) == 1, "MCP cwd is not a directory")
    assert(c.env == nil or type(c.env) == "table", "Invalid MCP environment")
    for key, value in pairs(c.env or {}) do
      assert(
        type(key) == "string"
          and type(value) == "string"
          and not key:find("[=%z]")
          and not value:find("%z"),
        "Invalid MCP environment entry"
      )
    end
    c.startup_timeout_ms = positive(c.startup_timeout_ms, 30000, 300000)
    c.request_timeout_ms = positive(c.request_timeout_ms, 60000, 300000)
    c.max_output_bytes = positive(c.max_output_bytes, 65536, 1048576)
    configs[name] = c
  end
  local previous = M.servers
  for name, entry in pairs(previous) do
    if not vim.deep_equal(entry.config, configs[name]) then
      M.stop(name)
    end
  end
  M.servers = {}
  for name, config in pairs(configs) do
    M.servers[name] = previous[name]
        and vim.deep_equal(previous[name].config, config)
        and previous[name]
      or { config = config, diagnostics = {} }
  end
end

function M.ensure(name, callback)
  local entry = M.servers[name]
  if not entry then
    callback("Unknown trusted MCP server: " .. tostring(name))
    return
  end
  if entry.waiters then
    entry.waiters[#entry.waiters + 1] = callback
    return
  end
  if
    entry.client
    and entry.client.state == "ready"
    and entry.tools
    and not entry.client.dirty
  then
    callback(nil, entry)
    return
  end
  if entry.client and entry.client.state == "failed" then
    callback(entry.client.error)
    return
  end
  entry.waiters = { callback }
  local function complete(err)
    local waiters = entry.waiters or {}
    entry.waiters = nil
    for _, waiter in ipairs(waiters) do
      if err then
        waiter(err)
      else
        waiter(nil, entry)
      end
    end
  end
  local function discover(err)
    if err then
      complete(err)
      return
    end
    entry.client:list_tools(function(list_err, tools)
      if not list_err then
        entry.tools, entry.exposed, entry.diagnostics = tools, {}, {}
        local seen = {}
        for _, remote in ipairs(tools) do
          if type(remote) ~= "table" or type(remote.name) ~= "string" then
            list_err = "Invalid MCP tool definition"
            break
          end
          if vim.tbl_contains(entry.config.tools, remote.name) then
            local tool, adapter_err =
              require("sia.mcp.tools").wrap(name, remote, entry.client, entry.config)
            if tool and not seen[tool.definition.name] then
              seen[tool.definition.name] = true
              entry.exposed[#entry.exposed + 1] = tool
            else
              entry.diagnostics[#entry.diagnostics + 1] = adapter_err
                or "Duplicate remote tool"
            end
          end
        end
      end
      if list_err then
        entry.tools, entry.exposed = nil, nil
      end
      complete(list_err)
    end)
  end
  if entry.client and entry.client.state == "ready" then
    discover()
    return
  end
  entry.client = require("sia.mcp.client").new(entry.config)
  entry.client:start(discover)
end

-- Called once at each safe request boundary. Existing requests retain their mappings.
function M.prepare(conversation, callback)
  local selected = conversation.mcp_servers or {}
  if conversation.project_mcp then
    local lc = require("sia.config").get_local_config()
    selected = vim.deepcopy(lc and lc.mcp or {})
    conversation.mcp_servers = selected
  end
  local remaining, prepared = #selected, {}
  local function finish()
    remaining = remaining - 1
    if remaining > 0 then
      return
    end
    local definitions = {}
    for _, definition in ipairs(conversation.tool_definitions) do
      if not (conversation.mcp_names or {})[definition.name] then
        definitions[#definitions + 1] = definition
      end
    end
    for name in pairs(conversation.mcp_names or {}) do
      conversation.tool_implementation[name] = nil
    end
    conversation.mcp_names = {}
    for _, server in ipairs(selected) do
      for _, tool in ipairs(prepared[server] or {}) do
        local name = tool.definition.name
        if not conversation.tool_implementation[name] then
          conversation.mcp_names[name] = true
          conversation.tool_implementation[name] = tool.implementation
          definitions[#definitions + 1] = tool.definition
        end
      end
    end
    conversation.tool_definitions = definitions
    callback()
  end
  if #selected == 0 then
    finish()
    return
  end
  for _, name in ipairs(selected) do
    M.ensure(name, function(err, entry)
      if err then
        vim.notify("Sia MCP " .. name .. ": " .. err, vim.log.levels.WARN)
      else
        prepared[name] = entry.exposed
      end
      finish()
    end)
  end
end

function M.stop(name)
  for key, entry in pairs(M.servers) do
    if not name or key == name then
      if entry.client then
        entry.client:stop()
      end
      entry.client, entry.tools, entry.exposed = nil, nil, nil
    end
  end
end

function M.status()
  local result = {}
  for name, entry in pairs(M.servers) do
    local exposed, discovered = {}, {}
    for _, tool in ipairs(entry.exposed or {}) do
      exposed[#exposed + 1] = tool.definition.name
    end
    for _, tool in ipairs(entry.tools or {}) do
      discovered[#discovered + 1] = tool.name
    end
    result[name] = {
      state = entry.client and entry.client.state or "stopped",
      discovered = discovered,
      exposed = exposed,
      diagnostics = entry.diagnostics,
      error = entry.client and entry.client.error,
    }
  end
  return result
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    M.stop()
  end,
})
return M
