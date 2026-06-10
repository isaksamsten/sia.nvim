local openai = require("sia.provider.openai")

local M = {}

local function parse_time(value)
  if type(value) ~= "number" then
    return nil
  end
  if value > 10000000000 then
    return math.floor(value / 1000)
  end
  return value
end

local function get_model_value(model, ...)
  for _, key in ipairs({ ... }) do
    local value = model[key]
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function is_text_model(model)
  local id = model.id
  return type(id) == "string"
    and not id:find("whisper", 1, true)
    and not id:find("prompt%-guard")
    and not id:find("orpheus", 1, true)
end

local function supports_reasoning(model_id)
  return model_id == "openai/gpt-oss-120b"
    or model_id == "openai/gpt-oss-20b"
    or model_id == "qwen/qwen3-32b"
end

local function entry_from_model(model)
  local id = model.id
  --- @type sia.provider.ModelSpec
  local entry = {}

  local context_window = get_model_value(model, "context_window", "context_length")
  if type(context_window) == "number" then
    entry.context_window = context_window
  end

  local support = { tool_calls = true }
  if id == "meta-llama/llama-4-scout-17b-16e-instruct" then
    support.image = true
  end
  if supports_reasoning(id) then
    support.reasoning = true
  end
  entry.support = support

  local input_price = get_model_value(model, "input_price", "prompt_price")
  local output_price = get_model_value(model, "output_price", "completion_price")
  if type(input_price) == "number" and type(output_price) == "number" then
    entry.pricing = { input = input_price, output = output_price }
  end

  return entry
end

--- @param callback fun(entries: table<string, sia.provider.ModelSpec>?, err: string?)
local function discover(callback)
  local api_key = os.getenv("GROQ_API_KEY")
  if not api_key then
    callback(nil, "GROQ_API_KEY not set")
    return
  end

  vim.system(
    {
      "curl",
      "--silent",
      "--header",
      "Authorization: Bearer " .. api_key,
      "https://api.groq.com/openai/v1/models",
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
        if is_text_model(model) then
          local entry = entry_from_model(model)
          local created = parse_time(model.created)
          local active = model.active ~= false
          local deprecated = created and created < os.time() and not active
          if not deprecated then
            entries[model.id] = entry
          end
        end
      end

      callback(entries)
    end)
  )
end

--- @type sia.provider.ProviderSpec
M.spec = {
  implementations = {
    default = openai.completion_compatible(
      "https://api.groq.com/openai/",
      "v1/chat/completions",
      {
        api_key = function()
          return os.getenv("GROQ_API_KEY")
        end,
        prepare_parameters = function(data, _)
          data.stream_options = nil
        end,
      }
    ),
  },
  seed = {
    ["llama-3.3-70b-versatile"] = {
      context_window = 131072,
      support = { tool_calls = true },
      pricing = { input = 0.59, output = 0.79 },
    },
    ["llama-3.1-8b-instant"] = {
      context_window = 131072,
      support = { tool_calls = true },
      pricing = { input = 0.05, output = 0.08 },
    },
    ["openai/gpt-oss-120b"] = {
      context_window = 131072,
      support = { reasoning = true, tool_calls = true },
      pricing = { input = 0.15, output = 0.60 },
      options = { reasoning_effort = "medium", reasoning_format = "parsed" },
    },
    ["openai/gpt-oss-20b"] = {
      context_window = 131072,
      support = { reasoning = true, tool_calls = true },
      pricing = { input = 0.075, output = 0.30 },
      options = { reasoning_effort = "medium", reasoning_format = "parsed" },
    },
    ["qwen/qwen3-32b"] = {
      context_window = 131072,
      support = { reasoning = true, tool_calls = true },
      pricing = { input = 0.29, output = 0.59 },
      options = { reasoning_effort = "default", reasoning_format = "parsed" },
    },
    ["meta-llama/llama-4-scout-17b-16e-instruct"] = {
      context_window = 131072,
      support = { image = true, tool_calls = true },
      pricing = { input = 0.11, output = 0.34 },
    },
    ["groq/compound"] = {
      context_window = 131072,
      support = { tool_calls = true },
    },
    ["groq/compound-mini"] = {
      context_window = 131072,
      support = { tool_calls = true },
    },
  },
  discover = discover,
}

return M

