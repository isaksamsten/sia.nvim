local openai = require("sia.provider.openai")
local copilot = require("sia.provider.copilot")

return {
  openai_responses = openai.responses,
  copilot_responses = copilot.responses,
  openai = openai.completion,
  copilot = copilot.completion,
  gemini = openai.completion_compatible(
    "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
    {
      api_key = function()
        return os.getenv("GEMINI_API_KEY")
      end,
    }
  ),
  anthropic = require("sia.provider.anthropic"),
  openrouter = require("sia.provider.openrouter"),
  zai = openai.completion_compatible(
    "https://api.z.ai/api/coding/paas/v4/chat/completions",
    {
      api_key = function()
        return os.getenv("ZAI_CODING_API_KEY")
      end,
    }
  ),
}
