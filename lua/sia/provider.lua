local M = {}

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

--- @param strategy sia.Strategy
--- @param t table
local process_stream_chunk_tool = function(strategy, t)
  for i, v in ipairs(t) do
    local func = v["function"]
    --- Patch for gemini models
    if v.index == nil then
      v.index = i
      v.id = "tool_call_id_" .. v.index
    end

    if not strategy.tools[v.index] then
      strategy.tools[v.index] =
        { ["function"] = { name = "", arguments = "" }, type = v.type, id = v.id }
    end
    if func.name then
      strategy.tools[v.index]["function"].name = strategy.tools[v.index]["function"].name
        .. func.name
    end
    if func.arguments then
      strategy.tools[v.index]["function"].arguments = strategy.tools[v.index]["function"].arguments
        .. func.arguments
    end
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

  --- @param strategy sia.Strategy
  --- @param obj table
  --- @return boolean? abort return true to abort
  process_stream_chunk = function(strategy, obj)
    if obj.choices and #obj.choices > 0 then
      for _, choice in ipairs(obj.choices) do
        local delta = choice.delta
        if delta then
          local reasoning = delta.reasoning or delta.reasoning_content
          if reasoning and reasoning ~= "" then
            if
              not strategy:on_content_received({ reasoning = { content = reasoning } })
            then
              return true
            end
          end
          if delta.content and delta.content ~= "" then
            if not strategy:on_content_received({ content = delta.content }) then
              return true
            end
          end
          if delta.tool_calls and delta.tool_calls ~= "" then
            if strategy:on_tool_call_received(delta.tool_calls) then
              process_stream_chunk_tool(strategy, delta.tool_calls)
            else
              return true
            end
          end
        end
      end
    end
  end,

  prepare_messages = function(data, _, messages)
    data.messages = vim
      .iter(messages)
      --- @param m sia.Message
      :map(function(m)
        local message = { role = m.role, content = m.content }
        if m._tool_call then
          message.tool_call_id = m._tool_call.id
        end
        if m.tool_calls then
          message.tool_calls = {}
          for _, tool_call in ipairs(m.tool_calls) do
            table.insert(message.tool_calls, {
              ["function"] = tool_call["function"],
              id = tool_call.id,
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
      data.include = { "reasoning.encrypted_content" }
    end
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
      else
        table.insert(input, { role = m.role, content = m.content })
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

  process_stream_chunk = function(strategy, json)
    strategy.cache = strategy.cache or {} --[[@diagnostic disable-line]]
    if json.type == "response.created" then
      strategy.cache.response_id = json.response.id
    end
    if json.type == "response.reasoning_summary_text.delta" then
      strategy:on_content_received({ reasoning = { content = json.delta } })
    elseif json.type == "response.output_text.delta" then
      strategy:on_content_received({ content = json.delta })
    elseif
      json.type == "response.completed"
      and json.response
      and json.response.output
    then
      for i, item in ipairs(json.response.output) do
        if item.type == "function_call" and item.status == "completed" then
          strategy.tools[i] = {
            id = item.id,
            call_id = item.call_id,
            type = "function",
            ["function"] = {
              name = item.name,
              arguments = item.arguments or "",
            },
          }
        elseif item.type == "reasoning" then
          strategy:on_content_received({
            reasoning = { id = item.id, encrypted_content = item.encrypted_content },
          })
        end
      end
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

  ---Closure that manages token state and retrieves a valid Copilot API token
  ---@return string? token A valid Copilot API token or nil if the request fails
  return function()
    if token and token.expires_at > os.time() then
      return token.token
    end

    oauth = get_oauth_token()
    if not oauth then
      vim.notify("Sia: Can't find Copilot auth token")
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
    if status then
      token = json
      return token.token
    end
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
  process_stream_chunk = openai_completion.process_stream_chunk,
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
  process_stream_chunk = openai_responses.process_stream_chunk,
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
  process_stream_chunk = openai_completion.process_stream_chunk,
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
  process_stream_chunk = openai_completion.process_stream_chunk,
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
  process_stream_chunk = openai_completion.process_stream_chunk,
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
  process_stream_chunk = openai_completion.process_stream_chunk,
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
    process_stream_chunk = openai_completion.process_stream_chunk,
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
  process_stream_chunk = openai_completion.process_stream_chunk,
}

local OR_CACHING_PREFIXES = { "anthropic/", "google/" }

--- @type sia.config.Provider
M.openrouter = {
  base_url = "https://openrouter.ai/api/v1/chat/completions",
  api_key = function()
    return os.getenv("OPENROUTER_API_KEY")
  end,
  process_stream_chunk = openai_completion.process_stream_chunk,
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
  process_stream_chunk = openai_responses.process_stream_chunk,
}

return M
