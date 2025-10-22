local M = {}

--- @class sia.ProviderStream
--- @field strategy sia.Strategy
local ProviderStream = {}
ProviderStream.__index = ProviderStream

--- Create a new stream instance
--- @param strategy sia.Strategy
--- @return sia.ProviderStream
function ProviderStream.new(strategy)
  local self = setmetatable({
    strategy = strategy,
  }, ProviderStream)
  return self
end

--- @param obj table
--- @return boolean? abort true to abort
function ProviderStream:process_stream_chunk(_)
  return false
end

--- @return string[]? content
function ProviderStream:finalize() end

--- @param input { content: string?, reasoning: table?, tool_calls: sia.ToolCall[]?, extra: table? }
--- @return boolean success
function ProviderStream:send_content(input)
  return self.strategy:on_content_received(input)
end

--- @class sia.OpenAICompletionStream : sia.ProviderStream
--- @field pending_tool_calls sia.ToolCall[]
--- @field content string
local OpenAICompletionStream = {}
OpenAICompletionStream.__index = OpenAICompletionStream
setmetatable(OpenAICompletionStream, { __index = ProviderStream })

function OpenAICompletionStream.new(strategy)
  local self = ProviderStream.new(strategy)
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
          if not self:send_content({ reasoning = { content = reasoning } }) then
            return true
          end
        end
        if delta.content and delta.content ~= "" then
          if not self:send_content({ content = delta.content }) then
            return true
          end
          self.content = self.content .. delta.content
        end
        if delta.tool_calls and delta.tool_calls ~= "" then
          if not self.strategy:on_tool_call_received() then
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
  if not self:send_content({ tool_calls = self.pending_tool_calls }) then
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
--- @field pending_tool_calls sia.ToolCall[]
--- @field response_id integer?
--- @field content string
--- @field reasoning_summary string?
--- @field encrypted_reasoning {id: integer, content: string}?
local OpenAIResponsesStream = {}
OpenAIResponsesStream.__index = OpenAIResponsesStream
setmetatable(OpenAIResponsesStream, { __index = ProviderStream })

function OpenAIResponsesStream.new(strategy)
  local self = ProviderStream.new(strategy)
  setmetatable(self, OpenAIResponsesStream)
  --- @cast self sia.OpenAIResponsesStream
  self.pending_tool_calls = {}
  self.content = ""
  self.reasoning_summary = nil
  return self
end

function OpenAIResponsesStream:process_stream_chunk(json)
  if json.type == "response.created" then
    self.response_id = json.response.id
  end
  if json.type == "response.reasoning_summary_text.delta" then
    if not self:send_content({ reasoning = { content = json.delta } }) then
      return true
    end
  elseif json.type == "response.output_text.delta" then
    if not self:send_content({ content = json.delta }) then
      return true
    end
    self.content = self.content .. json.delta
  elseif json.type == "response.function_call_arguments.delta" then
    self.strategy:on_tool_call_received()
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
  if not self:send_content({ tool_calls = self.pending_tool_calls }) then
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

local prepare_parameters = function(data, model)
  local config = require("sia.config").options
  if model.n then
    data.n = model.n
  end

  if model.max_tokens then
    data.max_tokens = model.max_tokens
  end

  if not model.reasoning_effort then
    data.temperature = model.temperature or config.defaults.temperature
  end

  if model.temperature then
    data.temperature = model.temperature
  end
end

local openai_completion = {
  --- @param obj table
  --- @return sia.Usage?
  process_usage = function(obj)
    if obj.usage then
      return {
        total = obj.usage.total_tokens or nil,
        prompt = obj.usage.prompt_tokens or nil,
        completion = obj.usage.completion_tokens or nil,
        total_time = 0,
      }
    end
  end,

  --- @param json table The complete response JSON
  --- @return string? content The extracted text content, or nil if parsing fails
  process_response = function(json)
    if json.choices and #json.choices > 0 then
      return json.choices[1].message.content
    end
    return nil
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
  prepare_parameters = function(data, model)
    prepare_parameters(data, model)
    if data.stream then
      data.stream_options = { include_usage = true }
    end
  end,
}

local openai_responses = {
  --- @param json table The complete response JSON
  --- @return string? content The extracted text content, or nil if parsing fails
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

  prepare_parameters = function(data, model)
    prepare_parameters(data, model)
    data.store = false
    if model.can_reason or model.reasoning_effort then
      data.temperature = nil
      data.include = { "reasoning.encrypted_content" }
    end
  end,

  --- @param data table
  --- @param messages sia.Message[]
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

  process_usage = function(json)
    if json.type == "response.completed" and json.response.usage then
      local usage = json.response.usage
      return {
        total = usage.total_tokens or nil,
        prompt = usage.input_tokens or nil,
        completion = usage.output_tokens or nil,
        total_time = 0,
      }
    end
  end,
}

---Get a valid GitHub Copilot API key by:
---1. Looking up the OAuth token in the GitHub Copilot config
---2. Using the OAuth token to request a temporary access token from GitHub's API
---@return function(): string? Function that returns a valid Copilot API token or nil if unsuccessful
local function copilot_api_key()
  local token = nil
  local oauth = nil

  ---Find the appropriate configuration directory based on the OS
  ---@return string? config_path The full path to the config directory or nil if not found
  local function find_config()
    local config = vim.fn.expand("$XDG_CONFIG_HOME")
    if config and vim.fn.isdirectory(config) > 0 then
      return config
    elseif vim.fn.has("win32") > 0 then
      config = vim.fn.expand("~/AppData/Local")
      if vim.fn.isdirectory(config) > 0 then
        return config
      end
    else
      config = vim.fn.expand("~/.config")
      if vim.fn.isdirectory(config) > 0 then
        return config
      end
    end
  end

  ---Extract the OAuth token from the GitHub Copilot apps.json configuration file
  ---@return string? oauth_token The OAuth token if found, nil otherwise
  local function get_oauth_token()
    if oauth then
      return oauth
    end
    local config_home = find_config()
    if not config_home then
      return nil
    end
    local apps = config_home .. "/github-copilot/apps.json"
    if vim.fn.filereadable(apps) == 1 then
      local data = vim.json.decode(table.concat(vim.fn.readfile(apps), " "))
      for key, value in pairs(data) do
        if string.find(key, "github.com") then
          return value.oauth_token
        end
      end
    end
    return nil
  end

  ---Get the cache file path for storing the token
  ---@return string cache_path The full path to the cache file
  local function get_cache_path()
    local cache_dir = vim.fn.stdpath("cache") .. "/sia"
    if vim.fn.isdirectory(cache_dir) == 0 then
      vim.fn.mkdir(cache_dir, "p")
    end
    return cache_dir .. "/copilot_token.json"
  end

  ---Load token from disk cache if it exists
  ---@return table? token The cached token or nil if not found
  local function load_cached_token()
    local cache_path = get_cache_path()
    if vim.fn.filereadable(cache_path) == 0 then
      return nil
    end
    local status, cached = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(cache_path), ""))
    end)
    if status and cached then
      return cached
    end
    return nil
  end

  ---Save token to disk cache
  ---@param token_data table The token data to cache
  local function save_cached_token(token_data)
    local cache_path = get_cache_path()
    vim.fn.writefile({ vim.json.encode(token_data) }, cache_path)
  end

  ---Closure that manages token state and retrieves a valid Copilot API token
  ---@return string? token A valid Copilot API token or nil if the request fails
  return function()
    -- Check in-memory cache first
    if token and token.expires_at > os.time() then
      return token.token
    end

    -- Check disk cache
    token = load_cached_token()
    if token and token.expires_at and token.expires_at > os.time() then
      return token.token
    end

    -- Need to fetch a new token
    oauth = get_oauth_token()
    if not oauth then
      vim.notify("Sia: Can't find Copilot auth token")
      return nil
    end

    local cmd = table.concat({
      "curl",
      "--silent",
      '--header "Authorization: Bearer ' .. oauth .. '"',
      '--header "Content-Type: application/json"',
      '--header "Accept: application/json"',
      "https://api.github.com/copilot_internal/v2/token",
    }, " ")
    local response = vim.fn.system(cmd)
    local status, json = pcall(vim.json.decode, response)
    if status and json and json.token and json.expires_at then
      token = json
      save_cached_token(token)
      return token.token
    end
    return nil
  end
end

local copilot_extra_header = function(messages)
  local args = {}

  table.insert(args, "--header")
  table.insert(args, "Copilot-Integration-Id: vscode-chat")
  table.insert(args, "--header")
  table.insert(
    args,
    string.format(
      "editor-version: Neovim/%s.%s.%s",
      vim.version().major,
      vim.version().minor,
      vim.version().patch
    )
  )
  table.insert(args, "--header")
  local initiator = "user"
  local last = messages[#messages]
  if last and last.role == "tool" then
    initiator = "agent"
  end
  table.insert(args, "X-Initiator: " .. initiator)
  return args
end

--- @type sia.config.Provider
M.copilot = {
  base_url = "https://api.githubcopilot.com/chat/completions",
  api_key = copilot_api_key(),
  get_headers = copilot_extra_header,
  process_usage = openai_completion.process_usage,
  process_response = openai_completion.process_response,
  prepare_parameters = openai_completion.prepare_parameters,
  prepare_tools = openai_completion.prepare_tools,
  prepare_messages = openai_completion.prepare_messages,
  new_stream = OpenAICompletionStream.new,
}

--- @type sia.config.Provider
M.copilot_responses = {
  base_url = "https://api.githubcopilot.com/responses",
  api_key = copilot_api_key(),
  get_headers = copilot_extra_header,
  prepare_parameters = openai_responses.prepare_parameters,
  prepare_tools = openai_responses.prepare_tools,
  prepare_messages = openai_responses.prepare_messages,
  process_response = openai_responses.process_response,
  new_stream = OpenAIResponsesStream.new,
}

--- @type sia.config.Provider
M.openai = {
  base_url = "https://api.openai.com/v1/chat/completions",
  api_key = function()
    return os.getenv("OPENAI_API_KEY")
  end,
  process_usage = openai_completion.process_usage,
  process_response = openai_completion.process_response,
  prepare_parameters = openai_completion.prepare_parameters,
  prepare_tools = openai_completion.prepare_tools,
  prepare_messages = openai_completion.prepare_messages,
  new_stream = OpenAICompletionStream.new,
}

--- @type sia.config.Provider
M.gemini = {
  base_url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
  api_key = function()
    return os.getenv("GEMINI_API_KEY")
  end,
  process_usage = openai_completion.process_usage,
  process_response = openai_completion.process_response,
  add_parameters = openai_completion.prepare_parameters,
  prepare_tools = openai_completion.prepare_tools,
  prepare_messages = openai_completion.prepare_messages,
  new_stream = OpenAICompletionStream.new,
}

--- @type sia.config.Provider
M.anthropic = {
  base_url = "https://api.anthropic.com/v1/chat/completions",
  api_key = function()
    return os.getenv("ANTHROPIC_API_KEY")
  end,
  process_usage = openai_completion.process_usage,
  process_response = openai_completion.process_response,
  add_parameters = openai_completion.prepare_parameters,
  prepare_tools = openai_completion.prepare_tools,
  prepare_messages = openai_completion.prepare_messages,
  new_stream = OpenAICompletionStream.new,
}

--- @type sia.config.Provider
M.zai_coding = {
  base_url = "https://api.z.ai/api/coding/paas/v4/chat/completions",
  api_key = function()
    return os.getenv("ZAI_CODING_API_KEY")
  end,
  process_usage = openai_completion.process_usage,
  process_response = openai_completion.process_response,
  add_parameters = openai_completion.prepare_parameters,
  prepare_tools = openai_completion.prepare_tools,
  prepare_messages = openai_completion.prepare_messages,
  new_stream = OpenAICompletionStream.new,
}

M.ollama = function(port)
  --- @type sia.config.Provider
  return {
    base_url = string.format("http://localhost:%d/v1/chat/completions", port),
    api_key = function()
      return "ollama"
    end,
    process_usage = openai_completion.process_usage,
    process_response = openai_completion.process_response,
    add_parameters = openai_completion.prepare_parameters,
    prepare_tools = openai_completion.prepare_tools,
    prepare_messages = openai_completion.prepare_messages,
    new_stream = OpenAICompletionStream.new,
  }
end

--- @type sia.config.Provider
M.morph = {
  base_url = "https://api.morphllm.com/v1/chat/completions",
  api_key = function()
    return os.getenv("MORPH_API_KEY")
  end,
  process_usage = openai_completion.process_usage,
  process_response = openai_completion.process_response,
  prepare_parameters = openai_completion.prepare_parameters,
  prepare_tools = openai_completion.prepare_tools,
  prepare_messages = openai_completion.prepare_messages,
  new_stream = OpenAICompletionStream.new,
}

local OR_CACHING_PREFIXES = { "anthropic/", "google/" }

--- @type sia.config.Provider
M.openrouter = {
  base_url = "https://openrouter.ai/api/v1/chat/completions",
  api_key = function()
    return os.getenv("OPENROUTER_API_KEY")
  end,
  new_stream = OpenAICompletionStream.new,
  process_response = openai_completion.process_response,
  process_usage = openai_completion.process_usage,
  prepare_parameters = openai_completion.prepare_parameters,
  prepare_tools = openai_completion.prepare_tools,
  prepare_messages = function(data, model, messages)
    openai_completion.prepare_messages(data, model, messages)
    local should_cache = false
    for _, prefix in ipairs(OR_CACHING_PREFIXES) do
      if model:find(prefix, 1, true) == 1 then
        should_cache = true
        break
      end
    end
    if not should_cache then
      return
    end

    local last_system_idx = nil
    local last_user_idx = nil
    for i = #data.messages, 1, -1 do
      if data.messages[i].role == "system" then
        last_system_idx = i
        break
      end
    end
    for i = #data.messages, 1, -1 do
      if data.messages[i].role == "user" then
        last_user_idx = i
        break
      end
    end
    for i, message in ipairs(data.messages) do
      if i == last_user_idx or i == last_system_idx then
        if type(message.content) == "string" then
          message.content = {
            {
              type = "text",
              text = message.content,
              cache_control = { type = "ephemeral" },
            },
          }
        else
          message.content[#message.content].cache_control = { type = "ephemeral" }
        end
      end
    end
  end,
}

--- @type sia.config.Provider
M.openai_responses = {
  base_url = "https://api.openai.com/v1/responses",
  api_key = function()
    return os.getenv("OPENAI_API_KEY")
  end,
  prepare_messages = openai_responses.prepare_messages,
  prepare_parameters = openai_responses.prepare_parameters,
  prepare_tools = openai_responses.prepare_tools,
  process_response = openai_responses.process_response,
  process_usage = openai_responses.process_usage,
  new_stream = OpenAIResponsesStream.new,
}

return M
