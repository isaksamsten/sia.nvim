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

--- @class sia.anthropic.ReasoningBlock
--- @field type "thinking"|"redacted_thinking"
--- @field thinking string?
--- @field signature string?
--- @field data string?

--- Convert a stored sia.Reasoning into the list of Anthropic content blocks
--- that must precede any text/tool_use content when round-tripping a turn.
--- Returns nil when there is nothing to emit.
--- @param reasoning sia.Reasoning?
--- @return table[]?
function M.reasoning_to_blocks(reasoning)
  if not reasoning then
    return nil
  end
  local opaque = reasoning.opaque
  local blocks = {}
  if type(opaque) == "table" and type(opaque.blocks) == "table" then
    for _, blk in ipairs(opaque.blocks) do
      if blk.type == "thinking" then
        local item = { type = "thinking", thinking = blk.thinking or "" }
        if blk.signature then
          item.signature = blk.signature
        end
        table.insert(blocks, item)
      elseif blk.type == "redacted_thinking" and blk.data then
        table.insert(blocks, { type = "redacted_thinking", data = blk.data })
      end
    end
  end
  if #blocks == 0 then
    return nil
  end
  return blocks
end

--- @class sia.AnthropicStream : sia.ProviderStream
--- @field pending_tool_calls sia.ToolCall[]
--- @field content string
--- @field reasoning_blocks sia.anthropic.ReasoningBlock[]
--- @field reasoning_text string
--- @field current_block_kind "thinking"|"redacted_thinking"|"text"|"tool_use"|nil
local AnthropicStream = {}
AnthropicStream.__index = AnthropicStream
setmetatable(AnthropicStream, { __index = common.ProviderStream })

function AnthropicStream.new(strategy)
  local self = common.ProviderStream.new(strategy)
  setmetatable(self, AnthropicStream)
  --- @cast self sia.AnthropicStream
  self.pending_tool_calls = {}
  self.content = ""
  self.reasoning_blocks = {}
  self.reasoning_text = ""
  self.current_block_kind = nil
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
      self.current_block_kind = "tool_use"
    elseif block.type == "thinking" then
      table.insert(self.reasoning_blocks, {
        type = "thinking",
        thinking = block.thinking or "",
        signature = block.signature,
      })
      self.current_block_kind = "thinking"
    elseif block.type == "redacted_thinking" then
      table.insert(self.reasoning_blocks, {
        type = "redacted_thinking",
        data = block.data,
      })
      self.current_block_kind = "redacted_thinking"
    elseif block.type == "text" then
      self.current_block_kind = "text"
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
    elseif delta.type == "thinking_delta" then
      local text = delta.thinking or ""
      if text ~= "" then
        if not self.strategy:on_stream({ reasoning = { content = text } }) then
          return true
        end
        self.reasoning_text = self.reasoning_text .. text
        local last = self.reasoning_blocks[#self.reasoning_blocks]
        if last and last.type == "thinking" then
          last.thinking = (last.thinking or "") .. text
        end
      end
    elseif delta.type == "signature_delta" then
      local last = self.reasoning_blocks[#self.reasoning_blocks]
      if last and last.type == "thinking" then
        last.signature = (last.signature or "") .. (delta.signature or "")
      end
    end
  elseif obj.type == "content_block_stop" then
    self.current_block_kind = nil
  end
end

--- @return sia.RoundResult
function AnthropicStream:finalize()
  local content
  if self.content ~= "" then
    content = self.content
  end

  --- @type sia.Reasoning?
  local reasoning
  if #self.reasoning_blocks > 0 then
    reasoning = {
      text = self.reasoning_text,
      opaque = { blocks = self.reasoning_blocks },
    }
  end

  --- @type sia.RoundResult
  return {
    content = content,
    reasoning = reasoning,
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

    if model and model.support and model.support.reasoning and not data.thinking then
      data.thinking = { type = "enabled", budget_tokens = 4096 }
    end

    if type(data.thinking) == "table" then
      if data.thinking.type == "disabled" then
        data.thinking = nil
      elseif data.thinking.type == "enabled" and not data.thinking.budget_tokens then
        data.thinking.budget_tokens = 4096
      end
    end

    if
      type(data.thinking) == "table"
      and data.thinking.budget_tokens
      and data.max_tokens
      and data.max_tokens <= data.thinking.budget_tokens
    then
      data.max_tokens = data.thinking.budget_tokens + 4096
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

        -- Preserve thinking blocks (with signatures) before tool_use so the
        -- API accepts the round-trip when extended thinking is enabled.
        local reasoning_blocks = M.reasoning_to_blocks(m.reasoning)
        if reasoning_blocks then
          for _, blk in ipairs(reasoning_blocks) do
            table.insert(content, blk)
          end
        end

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
      elseif m.role == "assistant" then
        local content = {}

        local reasoning_blocks = M.reasoning_to_blocks(m.reasoning)
        if reasoning_blocks then
          for _, blk in ipairs(reasoning_blocks) do
            table.insert(content, blk)
          end
        end

        if type(m.content) == "table" then
          for _, part in ipairs(m.content) do
            table.insert(content, part)
          end
        elseif m.content and m.content ~= "" then
          table.insert(content, { type = "text", text = m.content })
        end

        if #content == 0 then
          -- No reasoning, no text — skip emitting an empty assistant turn.
        elseif #content == 1 and not reasoning_blocks then
          -- Single text part, keep the simpler string form for compatibility.
          table.insert(conversation_messages, {
            role = "assistant",
            content = content[1].type == "text" and content[1].text or content,
          })
        else
          table.insert(conversation_messages, {
            role = "assistant",
            content = content,
          })
        end
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
