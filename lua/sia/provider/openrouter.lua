local common = require("sia.provider.common")
local openai = require("sia.provider.openai")
local OR_CACHING_PREFIXES = { "anthropic/", "google/" }

--- @type sia.config.Provider
return openai.completion_compatible("https://openrouter.ai/api/v1/chat/completions", {
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
})
