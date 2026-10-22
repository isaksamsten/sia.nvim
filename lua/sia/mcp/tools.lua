local M = {}

function M.schema(schema)
  if type(schema) ~= "table" or schema.type ~= "object" then
    return nil, "inputSchema must be an object"
  end
  local encoded, json = pcall(vim.json.encode, schema)
  if not encoded or #json > 65536 then
    return nil, "inputSchema exceeds 64 KiB or is not JSON"
  end
  -- Provider adapters can carry these root keywords without lossy conversion.
  local allowed = {
    type = true,
    properties = true,
    required = true,
    additionalProperties = true,
    description = true,
    ["$defs"] = true,
  }
  for key in pairs(schema) do
    if not allowed[key] then
      return nil, "unsupported root schema keyword: " .. tostring(key)
    end
  end
  if schema.properties ~= nil and type(schema.properties) ~= "table" then
    return nil, "invalid properties"
  end
  if
    schema.required ~= nil
    and (type(schema.required) ~= "table" or not vim.islist(schema.required))
  then
    return nil, "invalid required"
  end
  return vim.deepcopy(schema)
end

function M.normalize(result, limit)
  if type(result) ~= "table" then
    return "Invalid MCP tools/call result", true
  end
  local parts = {}
  for index, block in ipairs(type(result.content) == "table" and result.content or {}) do
    if index > 256 then
      parts[#parts + 1] = "[MCP content items truncated]"
      break
    end
    if type(block) ~= "table" then
      block = { type = "invalid" }
    end
    if block.type == "text" and type(block.text) == "string" then
      parts[#parts + 1] = block.text
    else
      parts[#parts + 1] = "[Unsupported MCP content: " .. tostring(block.type) .. "]"
    end
  end
  if result.structuredContent ~= nil then
    local structured = "Structured content (JSON):\n"
      .. vim.json.encode(result.structuredContent)
    if not vim.tbl_contains(parts, vim.json.encode(result.structuredContent)) then
      parts[#parts + 1] = structured
    end
  end
  local text = table.concat(parts, "\n")
  if #text > limit then
    -- Avoid cutting a multibyte UTF-8 character in half.
    while limit > 0 and text:byte(limit + 1) >= 128 and text:byte(limit + 1) < 192 do
      limit = limit - 1
    end
    text = text:sub(1, limit) .. "\n[MCP output truncated]"
  end
  if result.isError then
    text = "MCP tool reported an error:\n" .. text
  end
  return text, result.isError == true
end

function M.wrap(server, remote, client, config)
  local schema, err = M.schema(remote.inputSchema)
  if not schema then
    return nil, err
  end
  if type(remote.name) ~= "string" or #remote.name == 0 or #remote.name > 256 then
    return nil, "invalid remote tool name"
  end
  if
    remote.description ~= nil
    and (type(remote.description) ~= "string" or #remote.description > 8192)
  then
    return nil, "MCP tool description exceeds 8192 bytes or is invalid"
  end
  local suffix = vim.fn.sha256(server .. "\0" .. remote.name):sub(1, 12)
  local name = ("mcp_" .. server .. "_" .. remote.name):gsub("[^%w_-]", "_"):sub(1, 45)
    .. "_"
    .. suffix
  return require("sia.tools.utils").new_tool({
    definition = {
      type = "function",
      name = name,
      description = "External MCP tool ("
        .. server
        .. "): "
        .. (remote.description or remote.name),
      parameters = schema.properties or vim.empty_dict(),
      required = schema.required or {},
      input_schema = schema,
    },
    read_only = false,
    summary = function()
      return "Calling " .. remote.name .. " on " .. server
    end,
  }, function(args, _, callback, opts)
    if opts.cancellable and opts.cancellable.is_cancelled then
      callback({ content = "MCP call cancelled" })
      return
    end
    if client.state ~= "ready" then
      callback({
        content = "MCP server unavailable; prepare a new request or restart it",
      })
      return
    end
    local done, cancel = false, nil
    local function poll()
      if done then
        return
      end
      if opts.cancellable and opts.cancellable.is_cancelled then
        if cancel ~= nil then
          cancel()
        end
        return
      end
      vim.defer_fn(poll, 50)
    end
    cancel = client:request(
      "tools/call",
      { name = remote.name, arguments = next(args) and args or vim.empty_dict() },
      function(call_err, result)
        done = true
        local text = call_err or M.normalize(result, config.max_output_bytes)
        callback({
          content = text,
          summary = "Called " .. remote.name .. " on " .. server,
        })
      end
    )
    poll()
  end)
end
return M
