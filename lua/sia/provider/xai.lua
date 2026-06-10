local openai = require("sia.provider.openai")

local M = {}

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
  if type(id) ~= "string" then
    return false
  end

  return not id:find("image", 1, true)
    and not id:find("voice", 1, true)
    and not id:find("audio", 1, true)
    and not id:find("tts", 1, true)
end

local function supports_reasoning(model_id)
  return model_id:find("reasoning", 1, true) ~= nil
    or model_id:find("mini", 1, true) ~= nil
    or model_id:find("grok%-4") ~= nil
end

local function model_support(model)
  local id = model.id
  local support = { tool_calls = true }

  local input_modalities = get_model_value(model, "input_modalities", "input")
  if vim.tbl_contains(input_modalities or {}, "image") then
    support.image = true
  elseif id:find("vision", 1, true) or id:find("grok%-4") then
    support.image = true
  end

  if supports_reasoning(id) then
    support.reasoning = true
  end

  return support
end

local function entry_from_model(model)
  --- @type sia.provider.ModelSpec
  local entry = {}

  local context_window = get_model_value(model, "context_window", "context_length")
  if type(context_window) == "number" then
    entry.context_window = context_window
  end

  entry.support = model_support(model)

  return entry
end

--- @param callback fun(entries: table<string, sia.provider.ModelSpec>?, err: string?)
local function discover(callback)
  local api_key = os.getenv("XAI_API_KEY")
  if not api_key then
    callback(nil, "XAI_API_KEY not set")
    return
  end

  vim.system(
    {
      "curl",
      "--silent",
      "--header",
      "Authorization: Bearer " .. api_key,
      "https://api.x.ai/v1/models",
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
          entries[model.id] = entry_from_model(model)
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
      "https://api.x.ai/",
      "v1/chat/completions",
      {
        api_key = function()
          return os.getenv("XAI_API_KEY")
        end,
      }
    ),
  },
  seed = {
    ["grok-4.3"] = {
      context_window = 256000,
      support = { image = true, reasoning = true, tool_calls = true },
      pricing = { input = 3.00, output = 15.00 },
      cache_multiplier = { read = 0.25 },
    },
    ["grok-4.3-fast"] = {
      context_window = 256000,
      support = { image = true, reasoning = true, tool_calls = true },
      pricing = { input = 0.60, output = 3.00 },
      cache_multiplier = { read = 0.25 },
    },
    ["grok-4"] = {
      context_window = 256000,
      support = { image = true, reasoning = true, tool_calls = true },
      pricing = { input = 3.00, output = 15.00 },
      cache_multiplier = { read = 0.25 },
    },
    ["grok-4-fast-reasoning"] = {
      context_window = 2000000,
      support = { image = true, reasoning = true, tool_calls = true },
      pricing = { input = 0.20, output = 0.50 },
      cache_multiplier = { read = 0.25 },
    },
    ["grok-4-fast-non-reasoning"] = {
      context_window = 2000000,
      support = { image = true, tool_calls = true },
      pricing = { input = 0.20, output = 0.50 },
      cache_multiplier = { read = 0.25 },
    },
    ["grok-code-fast-1"] = {
      context_window = 256000,
      support = { tool_calls = true },
      pricing = { input = 0.20, output = 1.50 },
      cache_multiplier = { read = 0.25 },
    },
    ["grok-3"] = {
      context_window = 131072,
      support = { tool_calls = true },
      pricing = { input = 3.00, output = 15.00 },
      cache_multiplier = { read = 0.25 },
    },
    ["grok-3-mini"] = {
      context_window = 131072,
      support = { reasoning = true, tool_calls = true },
      pricing = { input = 0.30, output = 0.50 },
      cache_multiplier = { read = 0.25 },
    },
  },
  discover = discover,
}

return M

