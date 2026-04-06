local common = require("sia.provider.common")
local openai = require("sia.provider.openai")
local OR_CACHING_PREFIXES = { "anthropic/", "google/" }

local M = {}

--- @param price_str string?
--- @return number?
local function parse_price(price_str)
  if not price_str then
    return nil
  end
  local n = tonumber(price_str)
  if not n or n == 0 then
    return nil
  end
  return n * 1000000
end

--- @param id string
--- @return string
local function short_name_from_id(id)
  local slash = id:find("/", 1, true)
  if slash then
    return id:sub(slash + 1)
  end
  return id
end

--- @param callback fun(entries: table<string, sia.provider.ModelSpec>?, err: string?)
local function discover(callback)
  local api_key = os.getenv("OPENROUTER_API_KEY")

  local cmd = { "curl", "--silent" }
  if api_key then
    table.insert(cmd, "--header")
    table.insert(cmd, "Authorization: Bearer " .. api_key)
  end
  table.insert(cmd, "https://openrouter.ai/api/v1/models")

  vim.system(
    cmd,
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

      if not json.data or not vim.islist(json.data) then
        callback(nil, "unexpected response format")
        return
      end

      local entries = {}
      for _, model in ipairs(json.data) do
        local id = model.id
        if not id then
          goto continue
        end

        local short = short_name_from_id(id)
        --- @type sia.provider.ModelSpec
        local entry = {
          api_name = id,
        }

        if model.context_length then
          entry.context_window = model.context_length
        end

        local input_price = parse_price(model.pricing and model.pricing.prompt)
        local output_price = parse_price(model.pricing and model.pricing.completion)
        if input_price and output_price then
          entry.pricing = { input = input_price, output = output_price }
        end

        entries[short] = entry

        ::continue::
      end

      callback(entries)
    end)
  )
end

--- @type sia.provider.ProviderSpec
M.spec = {
  implementations = {
    default = openai.completion_compatible(
      "https://openrouter.ai/api/",
      "v1/chat/completions",
      {
        api_key = function()
          return os.getenv("OPENROUTER_API_KEY")
        end,
        prepare_messages = function(data, model, _)
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

          common.apply_prompt_caching(data.messages)
        end,
      }
    ),
  },
  seed = {},
  discover = discover,
}

return M
