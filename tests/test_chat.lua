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
local defaults = config.options.defaults
local vim_notify = vim.notify
config.get_local_config = function()
  return "mock/model"
end
T["strategy.chat"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      config.options.models["mock/model"] = { "mock", "mock-model" }
      config.options.defaults.model = "mock/model"
      config.options.defaults.fast_model = "mock/model"
      config.options.defaults.plan_model = "mock/model"
      vim.notify = function() end
    end,
    post_once = function()
      config.options.defaults = defaults
      vim.notify = vim_notify
    end,
  },
})
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

T["strategy.chat"]["is_busy flag management"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      mock.mock_fn_jobstart({
        {
          choices = {
            {
              delta = {
                content = "Response",
              },
            },
          },
        },
      })
    end,
    post_once = function()
      mock.unmock_assistant()
    end,
  },
})

T["strategy.chat"]["is_busy flag management"]["is reset after successful completion"] = function()
  local conversation = Conversation:new({
    instructions = {
      { role = "system", content = "Ok" },
    },
  }, nil)
  local strategy = ChatStrategy:new(conversation, { cmd = "split" })

  -- Should not be busy initially
  eq(strategy.is_busy, nil)

  assistant.execute_strategy(strategy)

  -- Should be reset after completion
  eq(strategy.is_busy, false)
end

T["strategy.chat"]["is_busy flag management"]["is reset on init failure"] = function()
  local conversation = Conversation:new({
    instructions = {
      { role = "system", content = "Ok" },
    },
  }, nil)
  local strategy = ChatStrategy:new(conversation, { cmd = "split" })

  -- Close the buffer to force on_init to fail
  vim.api.nvim_buf_delete(strategy.buf, { force = true })

  assistant.execute_strategy(strategy)

  -- Should be reset after on_init fails
  eq(strategy.is_busy, false)
end

T["strategy.chat"]["is_busy flag management"]["is reset on start failure"] = function()
  local conversation = Conversation:new({
    instructions = {
      { role = "system", content = "Ok" },
    },
  }, nil)
  local strategy = ChatStrategy:new(conversation, { cmd = "split" })
  local buf = strategy.buf

  -- Mock on_start to return false
  local original_on_start = strategy.on_start
  strategy.on_start = function(self)
    -- Delete buffer during on_start to simulate failure
    vim.api.nvim_buf_delete(buf, { force = true })
    return false
  end

  assistant.execute_strategy(strategy)

  -- Should be reset after on_start fails
  eq(strategy.is_busy, false)

  -- Restore original method
  strategy.on_start = original_on_start
end

T["strategy.chat"]["is_busy flag management"]["is reset on error response"] = function()
  -- Mock an error response
  mock.mock_fn_jobstart({
    error = {
      message = "API Error",
      type = "invalid_request_error",
    },
  })

  local conversation = Conversation:new({
    instructions = {
      { role = "system", content = "Ok" },
    },
  }, nil)
  local strategy = ChatStrategy:new(conversation, { cmd = "split" })

  assistant.execute_strategy(strategy)

  -- Should be reset after error
  eq(strategy.is_busy, false)

  -- Cleanup
  mock.unmock_assistant()
end

T["strategy.chat"]["is_busy flag management"]["prevents concurrent execution"] = function()
  local conversation = Conversation:new({
    instructions = {
      { role = "system", content = "Ok" },
    },
  }, nil)
  local strategy = ChatStrategy:new(conversation, { cmd = "split" })

  -- Set busy flag manually
  strategy.is_busy = true

  -- Try to execute - should return early
  assistant.execute_strategy(strategy)

  -- Should still be busy (wasn't reset because execution was skipped)
  eq(strategy.is_busy, true)

  -- Reset for cleanup
  strategy.is_busy = false
end

return T
