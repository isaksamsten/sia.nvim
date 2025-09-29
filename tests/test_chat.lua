local assistant = require("sia.assistant")
local mock = require("tests.mock")
local config = require("sia.config")
local ChatStrategy = require("sia.strategy").ChatStrategy
local Conversation = require("sia.conversation").Conversation

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
config.options.providers.mock = {
  base_url = "mock://provider",
  api_key = function()
    return "test-key"
  end,
}
config.options.models["mock/model"] = { "mock", "mock-model" }
config.options.defaults.model = "mock/model"
T["strategy.chat"] = MiniTest.new_set({})
T["strategy.chat"]["simple message"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      mock.mock_fn_jobstart({
        {
          choices = {
            {
              delta = {
                content = "Hello ",
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                content = "World",
              },
            },
          },
        },
      })
    end,
  },
  post_once = function()
    mock.unmock_assistant()
  end,
})
T["strategy.chat"]["simple message"]["test correct output"] = function()
  local conversation = Conversation:new({
    instructions = {
      { role = "system", content = "Ok" },
    },
  }, nil)
  local strategy = ChatStrategy:new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)
  eq("Hello World", strategy.conversation.messages[2]:get_content())
  eq({ "/sia", "", "Hello World" }, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
end

return T
