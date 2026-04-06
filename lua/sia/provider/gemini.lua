local M = {}

M.spec = {
  implementations = {
    default = require("sia.provider.openai").completion_compatible(
      "https://generativelanguage.googleapis.com/",
      "v1beta/openai/chat/completions",
      {
        api_key = function()
          return os.getenv("GEMINI_API_KEY")
        end,
      }
    ),
  },
  seed = {},
}

return M
