local common = require("sia.provider.common")
local get_headers = function(api_key, _)
  return { "--header", string.format("Authorization: Bearer %s", api_key) }
end

-- OpenAI Model Pricing (per 1M tokens, USD)
-- Last updated: 2025-01-10
-- Source: https://platform.openai.com/docs/pricing
local PRICING = {
  -- GPT-5 models
  ["gpt-5"] = { input = 1.25, output = 10.00 },
  ["gpt-5-mini"] = { input = 0.25, output = 2.00 },
  ["gpt-5-nano"] = { input = 0.05, output = 0.40 },
  ["gpt-5-chat-latest"] = { input = 1.25, output = 10.00 },
  ["gpt-5-codex"] = { input = 1.25, output = 10.00 },
  ["gpt-5-pro"] = { input = 15.00, output = 120.00 },

  -- GPT-4.1 models
  ["gpt-4.1"] = { input = 2.00, output = 8.00 },
  ["gpt-4.1-mini"] = { input = 0.40, output = 1.60 },
  ["gpt-4.1-nano"] = { input = 0.10, output = 0.40 },

  -- GPT-4o models
  ["gpt-4o"] = { input = 2.50, output = 10.00 },
  ["gpt-4o-2024-08-06"] = { input = 2.50, output = 10.00 },
  ["gpt-4o-2024-05-13"] = { input = 5.00, output = 15.00 },
  ["gpt-4o-mini"] = { input = 0.15, output = 0.60 },
  ["gpt-4o-mini-2024-07-18"] = { input = 0.15, output = 0.60 },

  -- o1 reasoning models
  ["o1"] = { input = 15.00, output = 60.00 },
  ["o1-pro"] = { input = 150.00, output = 600.00 },
  ["o1-mini"] = { input = 1.10, output = 4.40 },

  -- o3 reasoning models
  ["o3"] = { input = 2.00, output = 8.00 },
  ["o3-pro"] = { input = 20.00, output = 80.00 },
  ["o3-mini"] = { input = 1.10, output = 4.40 },
  ["o3-deep-research"] = { input = 10.00, output = 40.00 },

  -- o4 reasoning models
  ["o4-mini"] = { input = 1.10, output = 4.40 },
  ["o4-mini-deep-research"] = { input = 2.00, output = 8.00 },
}

local get_stats = common.create_cost_stats(PRICING, { read = 0.1 })

--- @class sia.OpenAICompletionStream : sia.ProviderStream
--- @field pending_tool_calls sia.ToolCall[]
--- @field content string
local OpenAICompletionStream = {}
OpenAICompletionStream.__index = OpenAICompletionStream
setmetatable(OpenAICompletionStream, { __index = common.ProviderStream })

function OpenAICompletionStream.new(strategy)
  local self = common.ProviderStream.new(strategy)
  setmetatable(self, OpenAICompletionStream)
  --- @cast self sia.OpenAICompletionStream
  self.pending_tool_calls = {}
  self.content = ""
  return self
end

function OpenAICompletionStream:process_stream_chunk(obj)
  if obj.choices and #obj.choices > 0 then
    for _, choice in ipairs(obj.choices) do
      local delta = choice.delta
      if delta then
        local reasoning = delta.reasoning or delta.reasoning_content
        if reasoning and reasoning ~= "" then
          if not self:on_content({ reasoning = { content = reasoning } }) then
            return true
          end
        end
        if delta.content and delta.content ~= "" then
          if not self:on_content({ content = delta.content }) then
            return true
          end
          self.content = self.content .. delta.content
        end
        if delta.tool_calls and delta.tool_calls ~= "" then
          if not self.strategy:on_tools() then
            return true
          end

          for i, v in ipairs(delta.tool_calls) do
            local func = v["function"]
            --- Patch for gemini models
            if v.index == nil then
              v.index = i
              v.id = "tool_call_id_" .. v.index
            end

            if not self.pending_tool_calls[v.index] then
              self.pending_tool_calls[v.index] = {
                ["function"] = { name = "", arguments = "" },
                type = v.type,
                id = v.id,
              }
            end
            if func.name then
              self.pending_tool_calls[v.index]["function"].name = self.pending_tool_calls[v.index]["function"].name
                .. func.name
            end
            if func.arguments then
              self.pending_tool_calls[v.index]["function"].arguments = self.pending_tool_calls[v.index]["function"].arguments
                .. func.arguments
            end
          end
        end
      end
    end
  end
end

--- @return string[]? content
function OpenAICompletionStream:finalize()
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

--- @class sia.OpenAIResponsesStream : sia.ProviderStream
--- @field private pending_tool_calls sia.ToolCall[]
--- @field private response_id integer?
--- @field private content string
--- @field private reasoning_summary string?
--- @field private tool_call_detected boolean
--- @field private encrypted_reasoning {id: integer, content: string}?
local OpenAIResponsesStream = {}
OpenAIResponsesStream.__index = OpenAIResponsesStream
setmetatable(OpenAIResponsesStream, { __index = common.ProviderStream })

function OpenAIResponsesStream.new(strategy)
  local self = common.ProviderStream.new(strategy)
  setmetatable(self, OpenAIResponsesStream)
  --- @cast self sia.OpenAIResponsesStream
  self.pending_tool_calls = {}
  self.content = ""
  self.reasoning_summary = nil
  self.tool_call_detected = false
  return self
end

function OpenAIResponsesStream:process_stream_chunk(json)
  if json.type == "response.created" then
    self.response_id = json.response.id
  end
  if json.type == "response.reasoning_summary_text.delta" then
    if not self:on_content({ reasoning = { content = json.delta } }) then
      return true
    end
  elseif json.type == "response.output_text.delta" then
    if not self:on_content({ content = json.delta }) then
      return true
    end
    self.content = self.content .. json.delta
  elseif
    json.type == "response.function_call_arguments.delta"
    and not self.tool_call_detected
  then
    self.strategy:on_tools()
    self.tool_call_detected = true
  elseif
    json.type == "response.completed"
    and json.response
    and json.response.output
  then
    for _, item in ipairs(json.response.output) do
      if item.type == "function_call" and item.status == "completed" then
        table.insert(self.pending_tool_calls, {
          id = item.id,
          call_id = item.call_id,
          type = "function",
          ["function"] = {
            name = item.name,
            arguments = item.arguments or "",
          },
        })
      elseif item.type == "reasoning" then
        self.encrypted_reasoning =
          { id = item.id, encrypted_content = item.encrypted_content }
        for _, subitem in ipairs(item.summary) do
          if subitem.type == "summary_text" then
            self.reasoning_summary = (self.reasoning_summary or "")
              .. subitem.text
              .. "\n"
          end
        end
      end
    end
  end
end

--- @return string[]? content
function OpenAIResponsesStream:finalize()
  if not self:on_content({ tool_calls = self.pending_tool_calls }) then
    return nil
  end

  local reasoning
  if self.encrypted_reasoning and self.reasoning_summary then
    reasoning = {
      summary = self.reasoning_summary,
      encrypted_content = self.encrypted_reasoning,
    }
  end

  if reasoning == nil and self.content == "" then
    return nil
  end

  local content
  if self.content ~= "" then
    content = vim.split(self.content, "\n")
  end

  self.strategy.conversation:add_instruction({
    hide = true,
    role = "assistant",
    content = content,
  }, nil, { meta = { reasoning = reasoning } })

  return content
end

local M = {
  --- @type sia.config.Provider
  completion = {
    base_url = "https://api.openai.com/v1/chat/completions",
    api_key = function()
      return os.getenv("OPENAI_API_KEY")
    end,
    get_headers = get_headers,
    process_usage = function(obj)
      if obj.usage then
        local cache_read = nil
        local input_tokens = obj.usage.prompt_tokens
        if
          obj.usage.prompt_tokens_details
          and obj.usage.prompt_tokens_details.cached_tokens
        then
          cache_read = obj.usage.prompt_tokens_details.cached_tokens
          -- Subtract cached tokens from input since prompt_tokens includes them
          if input_tokens and cache_read then
            input_tokens = input_tokens - cache_read
          end
        end
        return {
          total = obj.usage.total_tokens or nil,
          input = input_tokens or nil,
          output = obj.usage.completion_tokens or nil,
          cache_read = cache_read,
          total_time = 0,
        }
      end
    end,
    process_response = function(json)
      if json.choices and #json.choices > 0 then
        return json.choices[1].message.content
      end
      return nil
    end,
    prepare_parameters = function(data, model)
      common.prepare_parameters(data, model)
      if data.stream then
        data.stream_options = { include_usage = true }
      end
    end,
    prepare_tools = function(data, tools)
      if tools then
        data.tools = vim
          .iter(tools)
          --- @param tool sia.config.Tool
          :map(function(tool)
            return {
              type = "function",
              ["function"] = {
                name = tool.name,
                description = tool.description,
                parameters = {
                  type = "object",
                  properties = tool.parameters,
                  required = tool.required,
                  additionalProperties = false,
                },
              },
            }
          end)
          :totable()
      end
    end,
    prepare_messages = function(data, _, messages)
      --- We need to shorten the id if the user has used another provider
      --- @param id string
      local function shorten_id(id)
        if #id > 40 then
          return id:sub(1, 4)
        end
        return id
      end
      data.messages = vim
        .iter(messages)
        --- @param m sia.Message
        :map(function(m)
          local message = { role = m.role, content = m.content }
          if m._tool_call then
            message.tool_call_id = shorten_id(m._tool_call.id)
          end
          if m.tool_calls then
            message.tool_calls = {}
            for _, tool_call in ipairs(m.tool_calls) do
              table.insert(message.tool_calls, {
                ["function"] = tool_call["function"],
                id = shorten_id(tool_call.id),
                type = tool_call.type,
              })
            end
          end

          return message
        end)
        :totable()
    end,
    new_stream = OpenAICompletionStream.new,
    get_stats = get_stats,
  },

  responses = {
    base_url = "https://api.openai.com/v1/responses",
    api_key = function()
      return os.getenv("OPENAI_API_KEY")
    end,
    get_headers = get_headers,
    process_usage = function(json)
      if json.type == "response.completed" and json.response.usage then
        local usage = json.response.usage
        local cache_read = nil
        local input_tokens = usage.input_tokens
        if usage.input_tokens_details and usage.input_tokens_details.cached_tokens then
          cache_read = usage.input_tokens_details.cached_tokens
          -- Subtract cached tokens from input since input_tokens includes them
          if input_tokens and cache_read then
            input_tokens = input_tokens - cache_read
          end
        end
        return {
          total = usage.total_tokens or nil,
          input = input_tokens or nil,
          output = usage.output_tokens or nil,
          cache_read = cache_read,
          total_time = 0,
        }
      end
    end,
    process_response = function(json)
      if json.output then
        local texts = {}
        for _, output in ipairs(json.output) do
          if output.status == "completed" then
            for _, item in ipairs(output.content) do
              if item.type == "output_text" and item.text then
                table.insert(texts, item.text)
              end
            end
          end
        end
        if #texts > 0 then
          return table.concat(texts, "\n")
        end
      end
      return nil
    end,
    prepare_messages = function(data, _, messages)
      local instructions = vim
        .iter(messages)
        --- @param m sia.Message
        :filter(function(m)
          return m.role == "system"
        end)
        --- @param m sia.Message
        :map(function(m)
          return m.content or ""
        end)
        :totable()

      local i = 1
      local input = {}
      while i <= #messages do
        local m = messages[i]
        if m.role == "tool" then
          table.insert(input, {
            type = "function_call_output",
            call_id = m._tool_call.call_id,
            output = m.content,
          })
        elseif m.tool_calls then
          for _, tool_call in ipairs(m.tool_calls) do
            table.insert(input, {
              type = "function_call",
              id = tool_call.id,
              call_id = tool_call.call_id,
              name = tool_call["function"].name,
              arguments = tool_call["function"].arguments,
            })
          end
        elseif m.role ~= "system" then
          local reasoning = m.meta.reasoning
          if reasoning then
            local item = { type = "reasoning" }
            if reasoning.summary then
              item.summary = { type = "summary_text", text = reasoning.summary }
            end
            if reasoning.encrypted_content then
              item.encrypted_content = reasoning.encrypted_content
            end
            table.insert(input, item)
          else
            table.insert(input, { role = m.role, content = m.content })
          end
        end
        i = i + 1
      end

      data.instructions = #instructions > 0 and table.concat(instructions, "\n") or nil
      data.input = input
    end,
    prepare_parameters = function(data, model)
      common.prepare_parameters(data, model)
      data.store = false
      if model.can_reason or model.reasoning_effort then
        data.temperature = nil
        data.include = { "reasoning.encrypted_content" }
      end
    end,
    prepare_tools = function(data, tools)
      if not tools then
        return
      end
      data.tools = vim
        .iter(tools)
        --- @param tool sia.config.Tool
        :map(function(tool)
          return {
            type = "function",
            name = tool.name,
            description = tool.description,
            parameters = {
              type = "object",
              properties = tool.parameters,
              required = tool.required,
              additionalProperties = false,
            },
          }
        end)
        :totable()
    end,
    new_stream = OpenAIResponsesStream.new,
    get_stats = get_stats,
  },
}

--- @class sia.openai.CompatibleOpts
--- @field api_key fun():string?
--- @field prepare_messages fun(data: table, model:string, prompt:sia.Message[])?
--- @field prepare_tools fun(data: table, tools:sia.Tool[])?
--- @field prepare_parameters fun(data: table, model: table)?
--- @field get_headers (fun(api_key:string?, messages:sia.Message[]):string[])?

--- @param base_url string
--- @param opts sia.openai.CompatibleOpts
--- @return sia.config.Provider
function M.completion_compatible(base_url, opts)
  --- @type sia.config.Provider
  return {
    base_url = base_url,
    api_key = opts.api_key,
    prepare_parameters = function(data, model)
      M.completion.prepare_parameters(data, model)
      if opts.prepare_parameters then
        opts.prepare_parameters(data, model)
      end
    end,
    prepare_messages = function(data, model, messages)
      M.completion.prepare_messages(data, model, messages)
      if opts.prepare_messages then
        opts.prepare_messages(data, model, messages)
      end
    end,
    get_headers = function(api_key, messages)
      local headers = M.completion.get_headers(api_key, messages)
      if opts.get_headers then
        for _, header in ipairs(opts.get_headers(api_key, messages)) do
          table.insert(headers, header)
        end
      end
      return headers
    end,
    process_response = function(json)
      return M.completion.process_response(json)
    end,
    process_usage = function(json)
      return M.completion.process_usage(json)
    end,
    prepare_tools = function(data, tools)
      M.completion.prepare_tools(data, tools)
    end,
    new_stream = M.completion.new_stream,
    get_stats = common.create_cost_stats(nil),
  }
end

--- @return sia.config.Provider
function M.responses_compatible(base_url, opts)
  --- @type sia.config.Provider
  return {
    base_url = base_url,
    api_key = opts.api_key,
    prepare_parameters = function(data, model)
      M.responses.prepare_parameters(data, model)
      if opts.prepare_parameters then
        opts.prepare_parameters(data, model)
      end
    end,
    prepare_messages = function(data, model, messages)
      M.responses.prepare_messages(data, model, messages)
      if opts.prepare_messages then
        opts.prepare_messages(data, model, messages)
      end
    end,
    get_headers = function(api_key, messages)
      local headers = M.responses.get_headers(api_key, messages)
      if opts.get_headers then
        for _, header in ipairs(opts.get_headers(api_key, messages)) do
          table.insert(headers, header)
        end
      end
      return headers
    end,
    process_response = function(json)
      return M.responses.process_response(json)
    end,
    process_usage = function(json)
      return M.responses.process_usage(json)
    end,
    prepare_tools = function(data, tools)
      M.responses.prepare_tools(data, tools)
    end,
    new_stream = M.responses.new_stream,
  }
end

return M
