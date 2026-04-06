local common = require("sia.provider.common")
local get_headers = function(_, api_key, _)
  return { "--header", string.format("Authorization: Bearer %s", api_key) }
end

local HTTP_ERROR_CODE = {
  [402] = "This request requires more credits",
}

local function translate_http_error(code)
  return HTTP_ERROR_CODE[code]
end

-- OpenAI Model Pricing (per 1M tokens, USD)
-- Last updated: 2025-01-10
-- Source: https://platform.openai.com/docs/pricing
local PRICING = {
  -- GPT-5 models
  ["gpt-5.1"] = { input = 1.25, output = 10.00 },
  ["gpt-5.1-mini"] = { input = 0.25, output = 2.00 },
  ["gpt-5.1-codex"] = { input = 1.25, output = 10.00 },

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
--- @field pending_tool_calls table<integer, sia.ToolCall>
--- @field reasoning_opaque string?
--- @field reasoning_text string?
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
        local reasoning = delta.reasoning
          or delta.reasoning_content
          or delta.reasoning_text
        if reasoning and reasoning ~= "" then
          if not self.strategy:on_stream({ reasoning = { content = reasoning } }) then
            return true
          end
          self.reasoning_text = (self.reasoning_text or "") .. reasoning
        end
        if delta.content and delta.content ~= "" then
          if not self.strategy:on_stream({ content = delta.content }) then
            return true
          end
          self.content = self.content .. delta.content
        end
        -- Used by reasoning models...
        if delta.reasoning_opaque then
          self.reasoning_opaque = delta.reasoning_opaque
        end

        if delta.tool_calls and delta.tool_calls ~= "" then
          if not self.strategy:on_tools() then
            return true
          end

          for i, call in ipairs(delta.tool_calls) do
            local func = call["function"]
            --- Patch for gemini models
            if call.index == nil then
              call.index = i
              call.id = "tool_call_id_" .. call.index
            end

            if not self.pending_tool_calls[call.index] then
              self.pending_tool_calls[call.index] = {
                type = call.type,
                id = call.id,
                name = "",
                arguments = "",
              }
            end
            if func.name then
              self.pending_tool_calls[call.index].name = self.pending_tool_calls[call.index].name
                .. func.name
            end
            if func.arguments then
              self.pending_tool_calls[call.index].arguments = self.pending_tool_calls[call.index].arguments
                .. func.arguments
            end
          end
        end
      end
    end
  end
end

--- @return sia.RoundResult
function OpenAICompletionStream:finalize()
  --- @type sia.Reasoning?
  local reasoning
  if self.reasoning_text then
    reasoning = { text = self.reasoning_text }
    if self.reasoning_opaque then
      reasoning.opaque = self.reasoning_opaque
    end
  end

  local tool_calls = {}
  for _, tool_call in pairs(self.pending_tool_calls) do
    table.insert(tool_calls, tool_call)
  end

  local content
  if self.content ~= "" then
    content = self.content
  end

  --- @type sia.RoundResult
  return {
    content = content,
    reasoning = reasoning,
    tool_calls = tool_calls,
  }
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
  if json.type == "response.reasoning_summary_text.done" then
    if not self.strategy:on_stream({ reasoning = { content = json.text } }) then
      return true
    end
  elseif json.type == "response.output_text.delta" then
    if not self.strategy:on_stream({ content = json.delta }) then
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
    json.type == "response.custom_tool_call.delta" and not self.tool_call_detected
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
          name = item.name,
          arguments = item.arguments or "",
        })
      elseif item.type == "custom_tool_call" then
        table.insert(self.pending_tool_calls, {
          id = item.id,
          call_id = item.call_id,
          type = "custom",
          name = item.name,
          input = item.input or "",
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

--- @return sia.RoundResult
function OpenAIResponsesStream:finalize()
  --- @type sia.Reasoning?
  local reasoning
  if self.encrypted_reasoning and self.reasoning_summary then
    reasoning = {
      text = self.reasoning_summary,
      opaque = self.encrypted_reasoning,
    }
  end

  local content
  if self.content ~= "" then
    content = self.content
  end

  --- @type sia.RoundResult
  return {
    content = content,
    reasoning = reasoning,
    tool_calls = self.pending_tool_calls,
  }
end

local M = {
  --- @type sia.Provider
  completion = {
    base_url = "https://api.openai.com/",
    chat_endpoint = "v1/chat/completions",
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

      local response_format = model.response_format
      if response_format then
        data.response_format = response_format
      end

      if data.stream then
        data.stream_options = { include_usage = true }
      end
    end,
    --- @param data table
    --- @param tools sia.tool.Definition[]
    prepare_tools = function(data, tools)
      if tools then
        data.tools = vim
          .iter(tools)
          --- @param def sia.tool.Definition
          :filter(function(def)
            return def.type == "function"
          end)
          --- @param def sia.tool.Definition
          :map(function(def)
            return {
              type = "function",
              ["function"] = {
                name = def.name,
                description = def.description,
                parameters = {
                  type = "object",
                  properties = def.parameters,
                  required = def.required,
                  additionalProperties = false,
                },
              },
            }
          end)
          :totable()
      end
    end,
    prepare_messages = function(data, _, messages)
      local new_messages = vim
        .iter(messages)
        --- @param m sia.Message
        :map(function(m)
          --- @type string|table
          local content = ""
          if type(m.content) == "table" then
            content = {}
            for _, part in
              ipairs(m.content --[[@as sia.MultiPart[] ]])
            do
              if part.type == "image" then
                table.insert(content, {
                  type = "image_url",
                  image_url = { url = part.image.url },
                })
              elseif part.type == "text" then
                table.insert(content, { type = "text", text = part.text })
              else
                error("unsupported or unknown part" .. vim.inspect(m.content))
              end
            end
          else
            content = m.content
          end
          local message = { role = m.role, content = content }
          if m.role == "tool" and m.tool_call then
            message.tool_call_id = m.tool_call.id
          end
          if m.role == "assistant" and m.tool_call and m.tool_call then
            message.tool_calls = {
              {
                ["function"] = {
                  name = m.tool_call.name,
                  arguments = m.tool_call.arguments,
                },
                id = m.tool_call.id,
                type = m.tool_call.type,
              },
            }
          end
          if m.role ~= "system" then
            if m.reasoning then
              if m.reasoning.opaque then
                message.reasoning_opaque = m.reasoning.opaque
              end
              message.reasoning_text = m.reasoning.text
            end
          end

          return message
        end)
        :totable()

      local merged = common.merge_consecutive_messages(new_messages, {
        text_part_type = "text",
        can_merge = function(prev, msg)
          return prev.role == "user"
            and not msg.tool_calls
            and not prev.tool_calls
            and not msg.tool_call_id
            and not prev.tool_call_id
        end,
      })

      data.messages = {}
      local i = 1
      while i <= #merged do
        local current = merged[i]
        local next = i < #merged and merged[i + 1] or nil
        if
          next
          and next.role == current.role
          and next.tool_calls
          and not next.content
        then
          current.tool_calls = next.tool_calls
          i = i + 1
        end
        i = i + 1
        table.insert(data.messages, current)
      end
    end,
    new_stream = OpenAICompletionStream.new,
    get_stats = get_stats,
  },

  --- @type sia.Provider
  responses = {
    base_url = "https://api.openai.com/",
    chat_endpoint = "v1/responses",
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

        --- @type string|table
        local content = ""
        if type(m.content) == "table" then
          content = {}
          for _, part in
            ipairs(m.content --[[@as sia.MultiPart[] ]])
          do
            if part.type == "image" then
              table.insert(content, {
                type = "input_image",
                detail = part.image.detail or "auto",
                image_url = part.image.url,
              })
            elseif part.type == "text" then
              table.insert(content, { type = "input_text", text = part.text })
            elseif part.type == "file" then
              table.insert(content, {
                type = "input_file",
                file_data = part.file.file_data,
                detail = part.file.detail,
                filename = part.file.filename,
              })
            else
              error("unknown part")
            end
          end
        else
          content = m.content
        end
        if m.role == "tool" then
          if m.tool_call.type == "custom" then
            table.insert(input, {
              type = "custom_tool_call_output",
              call_id = m.tool_call.call_id,
              output = content,
            })
          else
            table.insert(input, {
              type = "function_call_output",
              call_id = m.tool_call.call_id,
              output = content,
            })
          end
        elseif m.role == "assistant" and m.tool_call then
          local call = m.tool_call
          if call and call.type == "custom" then
            table.insert(input, {
              type = "custom_tool_call",
              id = call.id,
              call_id = call.call_id,
              name = call.name,
              input = call.input,
            })
          elseif call and call.type == "function" then
            table.insert(input, {
              type = "function_call",
              id = call.id,
              call_id = call.call_id,
              name = call.name,
              arguments = call.arguments,
            })
          end
        elseif m.role ~= "system" then
          local reasoning = m.reasoning
          if reasoning then
            local item = { type = "reasoning" }
            if reasoning.text then
              item.summary = { { type = "summary_text", text = reasoning.text } }
            end
            if reasoning.opaque then
              item.id = reasoning.opaque.id
              item.encrypted_content = reasoning.opaque.encrypted_content
            end
            table.insert(input, item)
          else
            table.insert(input, { role = m.role, content = content })
          end
        end
        i = i + 1
      end

      -- Responses input allows structural items between turns, so only merge
      -- adjacent user messages and let assistant items stay distinct.
      local merged = common.merge_consecutive_messages(input, {
        text_part_type = "input_text",
        can_merge = function(prev)
          return prev.role == "user"
        end,
      })

      data.instructions = #instructions > 0 and table.concat(instructions, "\n") or nil
      data.input = merged
    end,
    --- @param model sia.Model
    prepare_parameters = function(data, model)
      common.prepare_parameters(data, model)

      local response_format = model.response_format
      if response_format then
        data.text = data.text or {}
        if
          response_format.type == "json_schema"
          and type(response_format.json_schema) == "table"
        then
          local js = response_format.json_schema
          data.text.format = {
            type = "json_schema",
            name = js.name,
            schema = js.schema,
            strict = js.strict,
          }
        else
          data.text.format = response_format
        end
      end

      if model.support.reasoning then
        data.include = { "reasoning.encrypted_content" }
      end
      data.store = false
    end,
    --- @param data table
    --- @param tools sia.tool.Definition[]
    prepare_tools = function(data, tools)
      data.tools = vim
        .iter(tools)
        --- @param tool sia.tool.Definition
        :map(function(tool)
          if tool.type == "custom" then
            return {
              type = "custom",
              name = tool.name,
              description = tool.description,
              format = tool.format,
            }
          end
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
    translate_http_error = translate_http_error,
    new_stream = OpenAIResponsesStream.new,
    get_stats = get_stats,
  },
}

--- @class sia.openai.CompatibleOpts
--- @field api_key fun():string?
--- @field prepare_messages fun(data: table, model:string, prompt:sia.Message[])?
--- @field prepare_tools fun(data: table, tools:sia.tool.Definition[])?
--- @field translate_http_error (fun(code: integer):string?)?
--- @field prepare_parameters fun(data: table, model: table)?
--- @field get_headers (fun(model: sia.Model, api_key:string?, messages:sia.Message[]):string[])?

--- @param base_url string
--- @param opts sia.openai.CompatibleOpts
--- @return sia.Provider
function M.completion_compatible(base_url, chat_endpoint, opts)
  --- @type sia.Provider
  return {
    base_url = base_url,
    chat_endpoint = chat_endpoint,
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
    get_headers = function(model, api_key, messages)
      local headers = M.completion.get_headers(model, api_key, messages)
      if opts.get_headers then
        for _, header in ipairs(opts.get_headers(model, api_key, messages)) do
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
    get_stats = common.create_cost_stats(),
  }
end

--- @param base_url string
--- @param chat_endpoint string
--- @param opts sia.openai.CompatibleOpts
--- @return sia.Provider
function M.responses_compatible(base_url, chat_endpoint, opts)
  --- @type sia.Provider
  return {
    base_url = base_url,
    chat_endpoint = chat_endpoint,
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
    get_headers = function(model, api_key, messages)
      local headers = M.responses.get_headers(model, api_key, messages)
      if opts.get_headers then
        for _, header in ipairs(opts.get_headers(model, api_key, messages)) do
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
    translate_http_error = function(code)
      if opts.translate_http_error then
        return opts.translate_http_error(code)
      end
      return M.responses.translate_http_error(code)
    end,
    new_stream = M.responses.new_stream,
  }
end

local COMPLETION_MODELS = {
  ["gpt-4.1"] = true,
  ["gpt-4.1-mini"] = true,
  ["gpt-4.1-nano"] = true,
}

local EXCLUDE_PREFIXES = {
  "dall-e",
  "tts-",
  "whisper",
  "text-embedding",
  "babbage",
  "davinci",
  "omni-moderation",
  "o1-",
  "o3-",
  "o4-",
  "codex-",
  "chatgpt-",
  "gpt-3",
}

--- @param id string
--- @return boolean
local function should_exclude(id)
  for _, prefix in ipairs(EXCLUDE_PREFIXES) do
    if id:sub(1, #prefix) == prefix then
      return true
    end
  end
  if id:match(":ft%-") or id:match("%-preview$") then
    return true
  end
  return false
end

--- @param callback fun(entries: table<string, sia.provider.ModelSpec>?, err: string?)
local function discover(callback)
  local api_key = M.responses.api_key()
  if not api_key then
    callback(nil, "OPENAI_API_KEY not set")
    return
  end

  vim.system(
    {
      "curl",
      "--silent",
      "--header",
      "Authorization: Bearer " .. api_key,
      "https://api.openai.com/v1/models",
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
        callback(nil, json.error.message or vim.inspect(json.error))
        return
      end

      if not json.data or not vim.islist(json.data) then
        callback(nil, "unexpected response format")
        return
      end

      local entries = {}
      for _, model in ipairs(json.data) do
        local id = model.id
        if id and not should_exclude(id) then
          local entry = {}
          if COMPLETION_MODELS[id] then
            entry.implementation = "completion"
          end
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
    default = M.responses,
    completion = M.completion,
  },
  seed = {
    ["gpt-5.4"] = {
      context_window = 400000,
      support = { image = true, document = true, reasoning = true },
    },
    ["gpt-5.2"] = {
      context_window = 400000,
      support = { image = true, document = true, reasoning = true },
    },
    ["gpt-5.2-codex"] = {
      context_window = 400000,
      support = { image = true, document = true, reasoning = true },
    },
    ["gpt-5.1"] = {
      context_window = 400000,
      support = { image = true, document = true, reasoning = true },
    },
    ["gpt-5.1-codex"] = {
      context_window = 400000,
      support = { image = true, document = true, reasoning = true },
    },
    ["gpt-4.1"] = {
      implementation = "completion",
      context_window = 1047576,
    },
  },
  discover = discover,
}

return M
