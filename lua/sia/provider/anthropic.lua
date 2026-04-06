local common = require("sia.provider.common")

local M = {}
-- Pricing per 1M tokens (USD) - Standard tier
-- Last updated: 2025-01-10
-- Source: https://www.anthropic.com/pricing
local PRICING = {
  -- Claude 4.1 models
  ["claude-opus-4.1"] = { input = 15.00, output = 75.00 },

  -- Claude 4.5 models (standard pricing, ≤ 200K tokens)
  ["claude-sonnet-4.5"] = { input = 3.00, output = 15.00 },
  ["claude-haiku-4.5"] = { input = 1.00, output = 5.00 },

  -- Claude 4 models
  ["claude-opus-4"] = { input = 15.00, output = 75.00 },
  ["claude-4-sonnet-20250514"] = { input = 3.00, output = 15.00 },

  -- Claude 3.7 models
  ["claude-sonnet-3.7"] = { input = 3.00, output = 15.00 },
}

--- @class sia.AnthropicStream : sia.ProviderStream
--- @field pending_tool_calls sia.ToolCall[]
--- @field content string
local AnthropicStream = {}
AnthropicStream.__index = AnthropicStream
setmetatable(AnthropicStream, { __index = common.ProviderStream })

function AnthropicStream.new(strategy)
  local self = common.ProviderStream.new(strategy)
  setmetatable(self, AnthropicStream)
  --- @cast self sia.AnthropicStream
  self.pending_tool_calls = {}
  self.content = ""
  return self
end

function AnthropicStream:process_stream_chunk(obj)
  if obj.type == "content_block_start" then
    local block = obj.content_block
    if block.type == "tool_use" then
      if not self.strategy:on_tools() then
        return true
      end
      table.insert(self.pending_tool_calls, {
        id = block.id,
        type = "function",
        name = block.name,
        arguments = "",
      })
    end
  elseif obj.type == "content_block_delta" then
    local delta = obj.delta
    if delta.type == "text_delta" then
      if not self.strategy:on_stream({ content = delta.text }) then
        return true
      end
      self.content = self.content .. delta.text
    elseif delta.type == "input_json_delta" then
      if #self.pending_tool_calls > 0 then
        local last_tool = self.pending_tool_calls[#self.pending_tool_calls]
        last_tool.arguments = last_tool.arguments .. delta.partial_json
      end
    end
  end
end

--- @return sia.RoundResult
function AnthropicStream:finalize()
  local content
  if self.content ~= "" then
    content = self.content
  end

  --- @type sia.RoundResult
  return {
    content = content,
    reasoning = nil,
    tool_calls = self.pending_tool_calls,
  }
end

--- @type sia.Provider
M.messages = {
  base_url = "https://api.anthropic.com/",
  chat_endpoint = "v1/messages",
  api_key = function()
    return os.getenv("ANTHROPIC_API_KEY")
  end,
  process_usage = function(obj)
    if obj.type == "message_start" and obj.message and obj.message.usage then
      local usage = obj.message.usage
      local input = usage.input_tokens or 0
      local cache_write = usage.cache_creation_input_tokens or 0
      local cache_read = usage.cache_read_input_tokens or 0
      local output = usage.output_tokens or 0
      --- @type sia.Usage
      return {
        total = input + cache_read + cache_write + output,
        input = input,
        output = output,
        cache_read = cache_read,
        cache_write = cache_write,
        total_time = 0,
      }
    end
  end,
  process_response = function(json)
    if json.content then
      local texts = {}
      for _, block in ipairs(json.content) do
        if block.type == "text" then
          table.insert(texts, block.text)
        end
      end
      if #texts > 0 then
        return table.concat(texts, "\n")
      end
    end
    return nil
  end,
  prepare_parameters = function(data, model)
    common.prepare_parameters(data, model)
    -- Set required default value
    if not data.max_tokens then
      data.max_tokens = 4096
    end
  end,
  --- @param data table
  --- @param tools sia.tool.Definition[]
  prepare_tools = function(data, tools)
    if tools then
      data.tools = vim
        .iter(tools)
        --- @param tool sia.tool.Definition
        :filter(function(tool)
          return tool.type == "function"
        end)
        --- @param tool sia.tool.Definition
        :map(function(tool)
          return {
            name = tool.name,
            description = tool.description,
            input_schema = {
              type = "object",
              properties = tool.parameters,
              required = tool.required,
              additionalProperties = false,
            },
          }
        end)
        :totable()
    end
  end,
  prepare_messages = function(data, _, messages)
    local system_parts = {}
    local conversation_messages = {}

    for _, m in ipairs(messages) do
      if m.role == "system" then
        table.insert(system_parts, { type = "text", text = m.content })
      elseif m.role == "tool" then
        table.insert(conversation_messages, {
          role = "user",
          content = {
            {
              type = "tool_result",
              tool_use_id = m.tool_call.id,
              content = m.content,
            },
          },
        })
      elseif m.role == "assistant" and m.tool_call then
        local content = {}
        if m.content and m.content ~= "" then
          table.insert(content, {
            type = "text",
            text = m.content,
          })
        end
        local input
        local arguments = m.tool_call.arguments
        if arguments ~= "" then
          local ok, decoded = pcall(vim.json.decode, arguments)
          if ok and type(decoded) == "table" then
            input = decoded
          end
        end

        table.insert(content, {
          type = "tool_use",
          id = m.tool_call.id,
          name = m.tool_call.name,
          input = input or vim.empty_dict(),
        })
        table.insert(conversation_messages, {
          role = "assistant",
          content = content,
        })
      else
        table.insert(conversation_messages, {
          role = m.role,
          content = m.content,
        })
      end
    end

    local merged = common.merge_consecutive_messages(
      conversation_messages,
      { text_part_type = "text" }
    )

    if #system_parts > 0 then
      data.system = system_parts
    end
    data.messages = merged

    if data.system then
      data.system[#data.system].cache_control = { type = "ephemeral" }
    end
    common.apply_prompt_caching(data.messages)
  end,
  get_headers = function(model, api_key, _)
    return {
      "--header",
      "anthropic-version: 2023-06-01",
      "--header",
      string.format("x-api-key: %s", api_key or ""),
    }
  end,
  new_stream = AnthropicStream.new,
  get_stats = common.create_cost_stats(PRICING, { read = 0.1, write = 1.25 }),
}

--- @param callback fun(entries: table<string, sia.provider.ModelSpec>?, err: string?)
local function discover(callback)
  local api_key = M.messages.api_key()
  if not api_key then
    callback(nil, "ANTHROPIC_API_KEY not set")
    return
  end

  vim.system(
    {
      "curl",
      "--silent",
      "--header",
      "x-api-key: " .. api_key,
      "--header",
      "anthropic-version: 2023-06-01",
      "https://api.anthropic.com/v1/models",
    },
    { text = true },
    vim.schedule_wrap(function(response)
      if response.code ~= 0 then
        callback(nil, "curl failed with code " .. response.code)
        return
      end

      local ok, json = pcall(vim.json.decode, response.stdout)
      if not ok or not json then
        callback(nil, "JSON decode failed")
        return
      end

      if json.error then
        local msg = json.error.message or vim.inspect(json.error)
        callback(nil, msg)
        return
      end

      if not json.data or not vim.islist(json.data) then
        callback(nil, "unexpected response format")
        return
      end

      local entries = {}
      for _, model in ipairs(json.data) do
        local id = model.id
        if id then
          --- @type sia.provider.ModelSpec
          local entry = {
            -- Use the full API id as api_name since Anthropic uses
            -- versioned IDs like "claude-4.5-sonnet-20260620"
            api_name = id,
          }
          entries[id] = entry
        end
      end

      callback(entries)
    end)
  )
end

--- @type sia.provider.ProviderSpec
M.spec = {
  implementations = {
    default = M.messages,
  },
  seed = {
    ["claude-sonnet-4.5"] = {
      api_name = "claude-4.5-sonnet",
      context_window = 200000,
    },
  },
  discover = discover,
}

return M
