return {
  spec = {
    implementations = {
      default = require("sia.provider.openai").completion_compatible(
        "https://api.z.ai/api/coding/paas/",
        "v4/chat/completions",
        {
          api_key = function()
            return os.getenv("ZAI_CODING_API_KEY")
          end,
        }
      ),
    },
    seed = {
      ["glm-4.5"] = {
        api_name = "GLM-4.5",
        context_window = 128000,
      },
      ["glm-4.6"] = {
        api_name = "GLM-4.6",
        context_window = 128000,
      },
    },
  },
}
