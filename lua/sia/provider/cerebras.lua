local openai = require("sia.provider.openai")

local M = {}

local function parse_price(price)
  if price == nil then
    return nil
  end
  if type(price) == "number" then
    return price * 1000000
  end
  local n = tonumber(price)
  if not n or n == 0 then
    return nil
  end
  return n * 1000000
end

local function has_feature(model, feature)
  return vim.tbl_contains(model.supported_features or {}, feature)
end

local function model_support(model)
  local support = {}
  local has_any = false

  if vim.tbl_contains(model.input_modalities or {}, "image") then
    support.image = true
    has_any = true
  end
  if has_feature(model, "tools") then
    support.tool_calls = true
    has_any = true
  end
  if model.id == "gpt-oss-120b" or model.id == "zai-glm-4.7" then
    support.reasoning = true
    has_any = true
  end

  return has_any and support or nil
end

local function apply_response_format(data, model)
  if model.response_format then
    data.response_format = model.response_format
  end
end

local function normalize_messages(data)
  for _, message in ipairs(data.messages or {}) do
    if message.reasoning_text then
      message.reasoning = message.reasoning_text
      message.reasoning_text = nil
    end
    message.reasoning_opaque = nil
  end
end

--- @param callback fun(entries: table<string, sia.provider.ModelSpec>?, err: string?)
local function discover(callback)
  vim.system(
    {
      "curl",
      "--silent",
      "https://api.cerebras.ai/public/v1/models?format=openrouter",
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
        if type(id) == "string" then
          --- @type sia.provider.ModelSpec
          local entry = {}

          if type(model.context_length) == "number" then
            entry.context_window = model.context_length
          end

          local support = model_support(model)
          if support then
            entry.support = support
          end

          local input_price = parse_price(model.pricing and model.pricing.prompt)
          local output_price = parse_price(model.pricing and model.pricing.completion)
          if input_price and output_price then
            entry.pricing = { input = input_price, output = output_price }
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
    default = openai.completion_compatible(
      "https://api.cerebras.ai/",
      "v1/chat/completions",
      {
        api_key = function()
          return os.getenv("CEREBRAS_API_KEY")
        end,
        prepare_parameters = function(data, model)
          apply_response_format(data, model)
          data.stream_options = nil
        end,
        prepare_messages = function(data)
          normalize_messages(data)
        end,
      }
    ),
  },
  seed = {
    ["gpt-oss-120b"] = {
      context_window = 131000,
      support = { reasoning = true, tool_calls = true },
      options = {
        reasoning_effort = "medium",
        reasoning_format = "parsed",
      },
    },
    ["zai-glm-4.7"] = {
      context_window = 131000,
      support = { reasoning = true, tool_calls = true },
      options = {
        reasoning_format = "parsed",
        clear_thinking = false,
      },
    },
    ["qwen-3-235b-a22b-instruct-2507"] = {
      context_window = 131000,
      support = { tool_calls = true },
    },
    ["llama3.1-8b"] = {
      context_window = 131000,
      support = { tool_calls = true },
    },
  },
  discover = discover,
}

return M
