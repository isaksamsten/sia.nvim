local common = require("sia.provider.common")

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
        ["function"] = {
          name = block.name,
          arguments = "",
        },
      })
    end
  elseif obj.type == "content_block_delta" then
    local delta = obj.delta
    if delta.type == "text_delta" then
      if not self:on_content({ content = delta.text }) then
        return true
      end
      self.content = self.content .. delta.text
    elseif delta.type == "input_json_delta" then
      if #self.pending_tool_calls > 0 then
        local last_tool = self.pending_tool_calls[#self.pending_tool_calls]
        last_tool["function"].arguments = last_tool["function"].arguments
          .. delta.partial_json
      end
    end
  end
end

--- @return string[]? content
function AnthropicStream:finalize()
  if not self:on_content({ tool_calls = self.pending_tool_calls }) then
    return nil
  end

  if self.content == "" then
    return nil
  end

  local content = vim.split(self.content, "\n")
  self.strategy.conversation:add_instruction({
    role = "assistant",
    content = content,
  })
  return content
end

--- @type sia.config.Provider
return {
  base_url = "https://api.anthropic.com/v1/messages",
  api_key = function()
    return os.getenv("ANTHROPIC_API_KEY")
  end,
  process_usage = function(obj)
    if obj.type == "message_start" and obj.message and obj.message.usage then
      local usage = obj.message.usage
      return {
        total = (usage.input_tokens or 0) + (usage.output_tokens or 0),
        prompt = usage.input_tokens or nil,
        completion = usage.output_tokens or nil,
        total_time = 0,
      }
    elseif obj.usage then
      return {
        total = (obj.usage.input_tokens or 0) + (obj.usage.output_tokens or 0),
        prompt = obj.usage.input_tokens or nil,
        completion = obj.usage.output_tokens or nil,
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
    if not data.max_tokens then
      data.max_tokens = 4096
    end
  end,
  prepare_tools = function(data, tools)
    if tools then
      data.tools = vim
        .iter(tools)
        --- @param tool sia.config.Tool
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
              tool_use_id = m._tool_call.id,
              content = m.content,
            },
          },
        })
      elseif m.tool_calls then
        local content = {}
        if m.content and m.content ~= "" then
          table.insert(content, {
            type = "text",
            text = m.content,
          })
        end
        for _, tool_call in ipairs(m.tool_calls) do
          local input
          local arguments = tool_call["function"].arguments
          if arguments ~= "" then
            local ok, decoded = pcall(vim.json.decode, arguments)
            if ok and type(decoded) == "table" then
              input = decoded
            end
          end

          table.insert(content, {
            type = "tool_use",
            id = tool_call.id,
            name = tool_call["function"].name,
            input = input or vim.empty_dict(),
          })
        end
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

    if #system_parts > 0 then
      data.system = system_parts
    end
    data.messages = conversation_messages

    if data.system then
      data.system[#data.system].cache_control = { type = "ephemeral" }
    end
    common.apply_prompt_caching(data.messages)
  end,
  get_headers = function(api_key, _)
    return {
      "--header",
      "anthropic-version: 2023-06-01",
      "--header",
      string.format("x-api-key: %s", api_key or ""),
    }
  end,
  new_stream = AnthropicStream.new,
}
