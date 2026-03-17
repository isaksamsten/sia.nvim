local assistant = require("sia.assistant")
local mock = require("tests.mock")
local config = require("sia.config")
local ChatStrategy = require("sia.strategy").ChatStrategy
local Conversation = require("sia.conversation")
local tracker = require("sia.tracker")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local settings = config._raw_options.settings
local vim_notify = vim.notify
config.get_local_config = function()
  return nil
end
T["strategy.chat"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      config.options.models["openai/test"] = { "openai", "test-model" }
      config.options.settings.model = "openai/test"
      config.options.settings.fast_model = "openai/test"
      config.options.settings.plan_model = "openai/test"
      vim.notify = function() end
    end,
    post_once = function()
      config._raw_options.settings = settings
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
  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/test"),
  })
  conversation:add_instruction({ role = "system", content = "Ok" })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)
  local messages = strategy.conversation:get_messages()
  eq("Hello World", messages[2].content)
  eq(
    { "/sia", "", "Hello World" },
    vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  )
end

T["strategy.chat"]["simple message"]["test tracking context"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "buffer " .. buf)
  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/test"),
  })
  conversation:add_instruction(
    { role = "user", kind = "context", content = "Here's the content of the file" },
    { tick = tracker.ensure_tracked(buf), buf = buf, global = true }
  )
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)

  eq(tracker.user_tick(buf, conversation.id), 0)
  eq(tracker.tracked_buffers[buf].global[1].refcount, 1)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  local messages = strategy.conversation:prepare_messages()
  eq(string.find(messages[1].content, "pruned") ~= nil, true)

  ChatStrategy.remove(strategy.buf)
  eq(tracker.user_tick(buf, conversation.id), -1)
  eq(tracker.tracked_buffers[buf].marked_for_deletion, true)
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
  local model = require("sia.model").resolve("openai/test")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_instruction({ role = "system", content = "Ok" })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  -- Should not be busy initially
  eq(strategy.is_busy, nil)

  assistant.execute_strategy(strategy)

  -- Should be reset after completion
  eq(strategy.is_busy, false)
end

T["strategy.chat"]["is_busy flag management"]["is reset on init failure"] = function()
  local model = require("sia.model").resolve("openai/test")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_instruction({ role = "system", content = "Ok" })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  vim.api.nvim_buf_delete(strategy.buf, { force = true })

  assistant.execute_strategy(strategy)

  eq(strategy.is_busy, false)
end

T["strategy.chat"]["is_busy flag management"]["is reset on start failure"] = function()
  local model = require("sia.model").resolve("openai/test")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_instruction({ role = "system", content = "Ok" })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  local buf = strategy.buf

  local original_on_start = strategy.on_stream_start
  strategy.on_stream_start = function(self)
    -- Delete buffer during on_start to simulate failure
    vim.api.nvim_buf_delete(buf, { force = true })
    return false
  end

  assistant.execute_strategy(strategy)

  -- Should be reset after on_start fails
  eq(strategy.is_busy, false)

  -- Restore original method
  strategy.on_stream_start = original_on_start
end

T["strategy.chat"]["is_busy flag management"]["is reset on error response"] = function()
  -- Mock an error response
  mock.mock_fn_jobstart({
    error = {
      message = "API Error",
      type = "invalid_request_error",
    },
  })

  local model = require("sia.model").resolve("openai/test")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_instruction({ role = "system", content = "Ok" })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  assistant.execute_strategy(strategy)

  -- Should be reset after error
  eq(strategy.is_busy, false)

  -- Cleanup
  mock.unmock_assistant()
end

T["strategy.chat"]["is_busy flag management"]["prevents concurrent execution"] = function()
  local model = require("sia.model").resolve("openai/test")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_instruction({ role = "system", content = "Ok" })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  -- Set busy flag manually
  strategy.is_busy = true

  -- Try to execute - should return early
  assistant.execute_strategy(strategy)

  -- Should still be busy (wasn't reset because execution was skipped)
  eq(strategy.is_busy, true)

  -- Reset for cleanup
  strategy.is_busy = false
end

T["strategy.chat"]["queued instructions"] = MiniTest.new_set()

T["strategy.chat"]["queued instructions"]["are flushed between rounds"] = function()
  local model = require("sia.model").resolve("openai/test")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_instruction({ role = "system", content = "Ok" })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  strategy:queue_instruction({ role = "user", content = "Queued follow-up" }, nil)

  eq(#strategy.queued_instructions, 1)

  local flushed = strategy:flush_queued_instructions()

  eq(flushed, true)
  eq(#strategy.queued_instructions, 0)
  eq(
    strategy.conversation.messages[#strategy.conversation.messages].content,
    "Queued follow-up"
  )
end

T["strategy.chat"]["reasoning rendering"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      mock.mock_fn_jobstart({
        {
          choices = {
            {
              delta = {
                reasoning_text = "Plan the change\nCheck the edge cases",
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                content = "Done",
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

T["strategy.chat"]["reasoning rendering"]["inserts folded reasoning into the buffer and preserves it on redraw"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/test"),
  })
  conversation:add_instruction({ role = "system", content = "Ok" })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  assistant.execute_strategy(strategy)

  local expected = {
    "/sia",
    "",
    ">| Plan the change",
    ">| Check the edge cases",
    "",
    "Done",
  }
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  local win = strategy:get_win()
  vim.api.nvim_set_current_win(win)
  eq("expr", vim.wo[win].foldmethod)
  eq(3, vim.fn.foldclosed(3))

  strategy:redraw()
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  eq(3, vim.fn.foldclosed(3))

  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["chunked reasoning"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      mock.mock_fn_jobstart({
        {
          choices = {
            {
              delta = {
                reasoning_text = "First ",
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                reasoning_text = "chunk\nSecond line",
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                content = "Result",
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

T["strategy.chat"]["chunked reasoning"]["assembles reasoning from multiple deltas"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/test"),
  })
  conversation:add_instruction({ role = "system", content = "Ok" })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  assistant.execute_strategy(strategy)

  local expected = {
    "/sia",
    "",
    ">| First chunk",
    ">| Second line",
    "",
    "Result",
  }
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["reasoning only"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      mock.mock_fn_jobstart({
        {
          choices = {
            {
              delta = {
                reasoning_text = "I thought about it",
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

T["strategy.chat"]["reasoning only"]["renders reasoning without content"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/test"),
  })
  conversation:add_instruction({ role = "system", content = "Ok" })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  assistant.execute_strategy(strategy)

  local expected = {
    "/sia",
    "",
    ">| I thought about it",
    "",
    "",
  }
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  ChatStrategy.remove(strategy.buf)
end

local child = MiniTest.new_child_neovim()

T["strategy.chat"]["multi-turn reasoning"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      child.restart({ "-u", "assets/minimal.lua" })
      child.lua([[
        vim.notify = function() end
      ]])
    end,
    post_once = function()
      child.stop()
    end,
  },
})

T["strategy.chat"]["multi-turn reasoning"]["reasoning in second turn after tool use"] = function()
  child.lua([[
    local mock = require("tests.mock")
    local assistant = require("sia.assistant")
    local ChatStrategy = require("sia.strategy").ChatStrategy
    local Conversation = require("sia.conversation")

    local call_count = 0
    mock.mock_fn_jobstart_custom(function(_, job_opts)
      call_count = call_count + 1
      local rounds = {
        {
          {
            choices = {
              {
                delta = {
                  reasoning_text = "Let me check",
                  tool_calls = {
                    {
                      index = 0,
                      id = "call_1",
                      type = "function",
                      ["function"] = { name = "test_tool", arguments = '{"q":"x"}' },
                    },
                  },
                },
              },
            },
          },
        },
        {
          { choices = { { delta = { reasoning_text = "Now I know" } } } },
          { choices = { { delta = { content = "The answer" } } } },
        },
      }
      local round = rounds[call_count]
      if round then
        for _, datum in ipairs(round) do
          job_opts.on_stdout(1, { "data: " .. vim.json.encode(datum) }, 10)
        end
      end
      job_opts.on_stdout(1, {
        "data: " .. vim.json.encode({
          choices = { { delta = {} } },
          usage = { total_tokens = 10 * call_count },
        }),
      }, 10)
      job_opts.on_stdout(1, { "data: [DONE]" }, nil)
      job_opts.on_exit(1, 0, nil)
      return 1
    end)

    local source_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, source_buf)

    local conversation = Conversation.new_conversation({
      model = require("sia.model").resolve("openai/gpt-4.1"),
    })
    conversation:add_instruction({ role = "system", content = "Ok" })

    conversation.tool_fn["test_tool"] = {
      action = function(_args, _conv, callback)
        callback({ content = { "tool result" }, kind = "ok" })
      end,
    }

    _G._test_strategy = ChatStrategy.new(conversation, { cmd = "split" })
    assistant.execute_strategy(_G._test_strategy)
  ]])

  child.lua([[
    _G._test_lines = vim.api.nvim_buf_get_lines(_G._test_strategy.buf, 0, -1, false)
  ]])

  local lines = child.lua_get("_G._test_lines")
  local expected = {
    "/sia",
    "",
    ">| Let me check",
    "",
    ">| Now I know",
    "",
    "The answer",
  }
  eq(expected, lines)
end

T["strategy.chat"]["multi-turn reasoning"]["content from turn 1 is not corrupted by turn 2 reasoning"] = function()
  child.lua([[
      local mock = require("tests.mock")
      local assistant = require("sia.assistant")
      local ChatStrategy = require("sia.strategy").ChatStrategy
      local Conversation = require("sia.conversation")

      local call_count = 0
      mock.mock_fn_jobstart_custom(function(_, job_opts)
        call_count = call_count + 1
        local rounds = {
          {
            { choices = { { delta = { reasoning_text = "First thought" } } } },
            {
              choices = {
                {
                  delta = {
                    content = "First content",
                    tool_calls = {
                      {
                        index = 0,
                        id = "call_1",
                        type = "function",
                        ["function"] = { name = "test_tool", arguments = "{}" },
                      },
                    },
                  },
                },
              },
            },
          },
          {
            { choices = { { delta = { reasoning_text = "Second thought" } } } },
            { choices = { { delta = { content = "Second content" } } } },
          },
        }
        local round = rounds[call_count]
        if round then
          for _, datum in ipairs(round) do
            job_opts.on_stdout(1, { "data: " .. vim.json.encode(datum) }, 10)
          end
        end
        job_opts.on_stdout(1, {
          "data: " .. vim.json.encode({
            choices = { { delta = {} } },
            usage = { total_tokens = 10 * call_count },
          }),
        }, 10)
        job_opts.on_stdout(1, { "data: [DONE]" }, nil)
        job_opts.on_exit(1, 0, nil)
        return 1
      end)

      local source_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_win_set_buf(0, source_buf)

      local conversation = Conversation.new_conversation({
        model = require("sia.model").resolve("openai/gpt-4.1"),
      })
      conversation:add_instruction({ role = "system", content = "Ok" })

      conversation.tool_fn["test_tool"] = {
        action = function(_args, _conv, callback)
          callback({ content = { "tool result" }, kind = "ok" })
        end,
      }

      _G._test_strategy = ChatStrategy.new(conversation, { cmd = "split" })
      assistant.execute_strategy(_G._test_strategy)
    ]])

  child.lua([[
      _G._test_lines = vim.api.nvim_buf_get_lines(_G._test_strategy.buf, 0, -1, false)
    ]])

  local lines = child.lua_get("_G._test_lines")
  local expected = {
    "/sia",
    "",
    ">| First thought",
    "",
    "First content",
    "",
    ">| Second thought",
    "",
    "Second content",
  }
  eq(expected, lines)
end

return T
