local M = {}
-- Text-first tools only; no roots, sampling, elicitation, resources or tasks.
M.VERSIONS = { ["2025-06-18"] = true, ["2024-11-05"] = true }

function M.new(config)
  local self = { state = "stopped", pending = {}, next_id = 0, config = config }
  function self:finish(id, err, result)
    local pending = self.pending[id]
    if not pending then
      return
    end
    self.pending[id] = nil
    pending.timer:stop()
    pending.timer:close()
    pending.callback(err, result)
  end
  function self:fail(reason)
    self.state = "failed"
    self.error = reason
    local ids = vim.tbl_keys(self.pending)
    for _, id in ipairs(ids) do
      self:finish(id, reason)
    end
  end
  function self:notify(method, params)
    return self.transport:send({ jsonrpc = "2.0", method = method, params = params })
  end
  function self:request(method, params, callback, timeout)
    self.next_id = self.next_id + 1
    local id = self.next_id
    local timer = vim.uv.new_timer()
    self.pending[id] = { callback = callback, timer = timer }
    timer:start(
      timeout or config.request_timeout_ms,
      0,
      vim.schedule_wrap(function()
        if self.pending[id] then
          self:notify(
            "notifications/cancelled",
            { requestId = id, reason = "Client timeout" }
          )
          self:finish(id, "MCP request timed out: " .. method)
        end
      end)
    )
    if
      not self.transport:send({
        jsonrpc = "2.0",
        id = id,
        method = method,
        params = params,
      })
    then
      self:finish(id, "MCP transport unavailable")
    end
    return function()
      if self.pending[id] then
        self:notify(
          "notifications/cancelled",
          { requestId = id, reason = "User cancelled" }
        )
        self:finish(id, "MCP request cancelled; server side effects may still occur")
      end
    end
  end
  function self:start(callback)
    self.state = "starting"
    local transport, err = require("sia.mcp.transport").start(config, function(message)
      if message.jsonrpc ~= "2.0" then
        self:fail("Invalid MCP JSON-RPC envelope")
        self.transport:stop()
        return
      end
      if message.method then
        if message.id ~= nil then
          local response = { jsonrpc = "2.0", id = message.id }
          if message.method == "ping" then
            response.result = vim.empty_dict()
          else
            response.error = { code = -32601, message = "Method not supported by Sia" }
          end
          self.transport:send(response)
        elseif message.method == "notifications/tools/list_changed" then
          self.dirty = true
        end
      elseif message.id ~= nil then
        local rpc_error = message.error
        if rpc_error ~= nil and type(rpc_error) ~= "table" then
          self:finish(message.id, "Invalid MCP error response")
        elseif rpc_error ~= nil then
          self:finish(message.id, "MCP protocol error " .. tostring(rpc_error.code))
        elseif message.result == nil then
          self:finish(message.id, "Invalid MCP response: missing result")
        else
          self:finish(message.id, nil, message.result)
        end
      end
    end, function(reason)
      self:fail(reason)
    end)
    if not transport then
      self:fail(err)
      callback(err)
      return
    end
    self.transport = transport
    self:request("initialize", {
      protocolVersion = "2025-06-18",
      capabilities = vim.empty_dict(),
      clientInfo = { name = "sia.nvim", version = "1" },
    }, function(init_err, result)
      if init_err then
        self:fail(init_err)
        transport:stop()
        callback(init_err)
        return
      end
      if type(result) ~= "table" or not M.VERSIONS[result.protocolVersion] then
        self:fail("Unsupported MCP protocol version; supported: 2025-06-18, 2024-11-05")
        transport:stop()
        callback(self.error)
        return
      end
      if type(result.capabilities) ~= "table" or not result.capabilities.tools then
        self:fail("MCP server does not advertise tools")
        transport:stop()
        callback(self.error)
        return
      end
      self.capabilities = result.capabilities
      self:notify("notifications/initialized", vim.empty_dict())
      self.state = "ready"
      callback(nil)
    end, config.startup_timeout_ms)
  end
  function self:list_tools(callback)
    local tools, cursors, pages = {}, {}, 0
    local function page(cursor)
      pages = pages + 1
      self:request(
        "tools/list",
        cursor and { cursor = cursor } or vim.empty_dict(),
        function(err, result)
          if err then
            callback(err)
            return
          end
          if type(result) ~= "table" or type(result.tools) ~= "table" then
            callback("Invalid MCP tools/list result")
            return
          end
          for _, tool in ipairs(result.tools) do
            if #tools >= 256 then
              callback("MCP discovery exceeds 256 tools")
              return
            end
            tools[#tools + 1] = tool
          end
          if result.nextCursor then
            if
              type(result.nextCursor) ~= "string"
              or cursors[result.nextCursor]
              or pages >= 32
            then
              callback("Invalid or excessive MCP pagination")
              return
            end
            cursors[result.nextCursor] = true
            page(result.nextCursor)
          else
            self.dirty = false
            callback(nil, tools)
          end
        end
      )
    end
    page()
  end
  function self:stop()
    self.state = "stopping"
    if self.transport then
      self.transport:stop()
    end
    self:fail("MCP server stopped")
    self.state = "stopped"
  end
  return self
end
return M
