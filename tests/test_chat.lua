local assistant = require("sia.assistant")
local mock = require("tests.mock")
local config = require("sia.config")
local ChatStrategy = require("sia.strategy").ChatStrategy
local Conversation = require("sia.conversation")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local settings = config._raw_options.settings
local vim_notify = vim.notify

local function cleanup_chat_test_state()
  pcall(vim.cmd, "silent! only!")

  for _, chat in ipairs(ChatStrategy.all()) do
    if vim.api.nvim_buf_is_valid(chat.buf) then
      pcall(vim.api.nvim_buf_delete, chat.buf, { force = true })
    end
    ChatStrategy.remove(chat.buf)
  end
end

config.get_local_config = function()
  return nil
end
T["strategy.chat"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      config.options.settings.model = "openai/gpt-4.1"
      config.options.settings.fast_model = "openai/gpt-4.1"
      config.options.settings.plan_model = "openai/gpt-4.1"
      vim.notify = function() end
    end,
    post_once = function()
      config._raw_options.settings = settings
      vim.notify = vim_notify
    end,
    post_case = function()
      cleanup_chat_test_state()
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
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)
  local messages = strategy.conversation:serialize()
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
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_user_message("Here's the content of the file", { buf = buf })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)

  eq(conversation.tracker:is_stale(buf, 0), false)

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })

  local messages = strategy.conversation:serialize()
  eq(string.find(messages[1].content --[[@as string]], "pruned") ~= nil, true)

  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["submit adds hidden skill messages before visible input"] = function()
  local model = require("sia.model").resolve("openai/gpt-4.1")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  local original_execute = assistant.execute_strategy
  local executed = false
  assistant.execute_strategy = function()
    executed = true
  end

  strategy:submit({
    hidden_messages = { "Skill payload" },
    content = "Visible prompt",
  })

  assistant.execute_strategy = original_execute

  eq(true, executed)
  eq("Skill payload", strategy.conversation.entries[2].content)
  eq(true, strategy.conversation.entries[2].hide)
  eq("Visible prompt", strategy.conversation.entries[3].content)
  eq(false, strategy.conversation.entries[3].hide)
end

T["strategy.chat"]["submit queues hidden skill messages while busy"] = function()
  local model = require("sia.model").resolve("openai/gpt-4.1")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy.is_busy = true

  strategy:submit({
    hidden_messages = { "Queued skill payload" },
    content = "Queued visible prompt",
  })

  eq(2, conversation:pending_user_message_count())
  eq("Queued skill payload", conversation.pending_user_messages[1].content)
  eq(true, conversation.pending_user_messages[1].hide)
  eq("Queued visible prompt", conversation.pending_user_messages[2].content)
  eq(nil, conversation.pending_user_messages[2].hide)

  strategy.is_busy = false
  eq(true, strategy:on_request_end())
  eq(0, conversation:pending_user_message_count())
  eq("Queued skill payload", strategy.conversation.entries[2].content)
  eq(true, strategy.conversation.entries[2].hide)
  eq("Queued visible prompt", strategy.conversation.entries[3].content)
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
  local model = require("sia.model").resolve("openai/gpt-4.1")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  eq(strategy.is_busy, nil)
  assistant.execute_strategy(strategy)
  eq(strategy.is_busy, false)
end

T["strategy.chat"]["is_busy flag management"]["is reset on init failure"] = function()
  local model = require("sia.model").resolve("openai/gpt-4.1")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  vim.api.nvim_buf_delete(strategy.buf, { force = true })
  assistant.execute_strategy(strategy)
  eq(strategy.is_busy, false)
end

T["strategy.chat"]["is_busy flag management"]["is reset on start failure"] = function()
  local model = require("sia.model").resolve("openai/gpt-4.1")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  local buf = strategy.buf

  local original_on_start = strategy.on_stream_start
  strategy.on_stream_start = function(self)
    vim.api.nvim_buf_delete(buf, { force = true })
    return false
  end

  assistant.execute_strategy(strategy)
  eq(strategy.is_busy, false)
  strategy.on_stream_start = original_on_start
end

T["strategy.chat"]["is_busy flag management"]["is reset on error response"] = function()
  mock.mock_fn_jobstart({
    error = {
      message = "API Error",
      type = "invalid_request_error",
    },
  })

  local model = require("sia.model").resolve("openai/gpt-4.1")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  assistant.execute_strategy(strategy)
  eq(strategy.is_busy, false)
  mock.unmock_assistant()
end

T["strategy.chat"]["is_busy flag management"]["prevents concurrent execution"] = function()
  local model = require("sia.model").resolve("openai/gpt-4.1")
  local conversation = Conversation.new_conversation({
    model = model,
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy.is_busy = true
  assistant.execute_strategy(strategy)
  eq(strategy.is_busy, true)
  strategy.is_busy = false
end

-- T["strategy.chat"]["queued instructions"] = MiniTest.new_set()
--
-- T["strategy.chat"]["queued instructions"]["are flushed between rounds"] = function()
--   local model = require("sia.model").resolve("openai/gpt-4.1")
--   local conversation = Conversation.new_conversation({
--     model = model,
--   })
--   conversation:add_instruction({ role = "system", content = "Ok" })
--   local strategy = ChatStrategy.new(conversation, { cmd = "split" })
--
--   strategy:enqueue_submit({ role = "user", content = "Queued follow-up" }, nil)
--
--   eq(#strategy.queue, 1)
--
--   local flushed = strategy:flush_queued_instructions()
--
--   eq(flushed, true)
--   eq(#strategy.queue, 0)
--   eq(
--     strategy.conversation.entries[#strategy.conversation.entries].content,
--     "Queued follow-up"
--   )
-- end

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
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
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
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
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
  strategy:redraw()
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
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  assistant.execute_strategy(strategy)

  local expected = {
    "/sia",
    "",
    ">| I thought about it",
    "",
  }
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  strategy:redraw()
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["tool summaries render inline and preserve details on redraw"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conversation:add_system_message("Ok")
  local turn_id = conversation:new_turn()
  conversation:add_assistant_message(turn_id, nil, { text = "Plan the check" })
  conversation:add_tool_message(
    turn_id,
    {
      key = "tool-1",
      id = "call_1",
      call_id = "call_1",
      type = "function",
      name = "bash",
      arguments = '{"bash_command":"make test"}',
    },
    "test output",
    {
      summary = {
        header = "Ran make test",
        details = "Last lines:\n- 120 passed\n- 2 skipped",
      },
    }
  )
  conversation:add_assistant_message(turn_id, "All good")

  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  local expected = {
    "/sia",
    "",
    ">| Plan the check",
    "Ran make test",
    ">! Last lines:",
    ">! - 120 passed",
    ">! - 2 skipped",
    "All good",
  }

  strategy:redraw()
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  local win = strategy:get_win()
  vim.api.nvim_set_current_win(win)
  eq(5, vim.fn.foldclosed(5))

  strategy:redraw()
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  eq(5, vim.fn.foldclosed(5))

  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["tool summaries render inline while running"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")

  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  eq(true, strategy:on_request_start())
  eq(true, strategy:on_stream_start())
  strategy.turn_renderer:append_reasoning("Plan the check")

  strategy:on_tool_status({
    {
      key = "tool-1",
      index = 1,
      name = "bash",
      summary = "Running bash: make test",
      status = "running",
    },
  })

  eq({
    "/sia",
    "",
    ">| Plan the check",
    "",
    "Running bash: make test",
    "",
  }, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  strategy:on_tool_results({
    {
      key = "tool-1",
      index = 1,
      name = "bash",
      summary = {
        header = "Ran make test",
        details = "Last lines:\n- 120 passed",
      },
      status = "done",
      actions = {},
    },
  })

  eq({
    "/sia",
    "",
    ">| Plan the check",
    "",
    "Ran make test",
    ">! Last lines:",
    ">! - 120 passed",
    "",
  }, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

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
    conversation:add_system_message("Ok")

    conversation.tool_implementation["test_tool"] = {
      summary = function() return "test_tool" end,
      execute = function(_args, callback, _opts)
        callback({ content = "tool result" })
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
    "test_tool",
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
      conversation:add_system_message("Ok")

      conversation.tool_implementation["test_tool"] = {
        summary = function() return "test_tool" end,
        execute = function(_args, callback, _opts)
          callback({ content = "tool result" })
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
    "test_tool",
    ">| Second thought",
    "",
    "Second content",
  }
  eq(expected, lines)
end

T["strategy.chat"]["multi-turn reasoning"]["tool-only round gets /sia header matching redraw"] = function()
  child.lua([[
    local mock = require("tests.mock")
    local assistant = require("sia.assistant")
    local ChatStrategy = require("sia.strategy").ChatStrategy
    local Conversation = require("sia.conversation")

    local call_count = 0
    mock.mock_fn_jobstart_custom(function(_, job_opts)
      call_count = call_count + 1
      local rounds = {
        -- Round 1: tool call only (no content, no reasoning)
        {
          {
            choices = {
              {
                delta = {
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
        -- Round 2: content response
        {
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
    conversation:add_system_message("Ok")

    conversation.tool_implementation["test_tool"] = {
      summary = function() return "test_tool" end,
      execute = function(_args, callback, _opts)
        callback({ content = "tool result" })
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
    "test_tool",
    "The answer",
  }
  eq(expected, lines)

  -- Verify redraw produces the same output
  child.lua([[
    _G._test_strategy:redraw()
    _G._test_redraw_lines = vim.api.nvim_buf_get_lines(_G._test_strategy.buf, 0, -1, false)
  ]])

  local redraw_lines = child.lua_get("_G._test_redraw_lines")
  eq(expected, redraw_lines)
end

T["strategy.chat"]["tool-only round renders /sia header on redraw"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conversation:add_system_message("Ok")
  local turn_id = conversation:new_turn()
  -- No assistant entry for this turn (model returned only tool calls)
  conversation:add_tool_message(
    turn_id,
    {
      key = "tool-1",
      id = "call_1",
      call_id = "call_1",
      type = "function",
      name = "bash",
      arguments = '{"bash_command":"ls"}',
    },
    "file1.txt\nfile2.txt",
    {
      summary = "Ran ls",
    }
  )
  conversation:add_assistant_message(turn_id, "Here are the files")

  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:redraw()

  local expected = {
    "/sia",
    "",
    "Ran ls",
    "Here are the files",
  }
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  -- Verify redraw is idempotent
  strategy:redraw()
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["tool-only round with multiple tools renders single /sia header"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conversation:add_system_message("Ok")
  local turn_id = conversation:new_turn()
  conversation:add_tool_message(turn_id, {
    key = "tool-1",
    id = "call_1",
    call_id = "call_1",
    type = "function",
    name = "bash",
    arguments = '{"bash_command":"ls"}',
  }, "file1.txt", { summary = "Ran ls" })
  conversation:add_tool_message(turn_id, {
    key = "tool-2",
    id = "call_2",
    call_id = "call_2",
    type = "function",
    name = "grep",
    arguments = '{"pattern":"hello"}',
  }, "match found", { summary = "Searched for hello" })
  conversation:add_assistant_message(turn_id, "Found it")

  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:redraw()

  local expected = {
    "/sia",
    "",
    "Ran ls",
    "Searched for hello",
    "Found it",
  }
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  ChatStrategy.remove(strategy.buf)
end

-- Test that empty string deltas don't produce extra empty lines in the chat buffer
T["strategy.chat"]["empty deltas rendering"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      mock.mock_fn_jobstart({
        {
          choices = {
            {
              delta = {
                content = "Hello",
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                content = "",
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                content = " World",
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

T["strategy.chat"]["empty deltas rendering"]["empty delta between content does not add lines"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)
  eq(
    { "/sia", "", "Hello World" },
    vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  )
  ChatStrategy.remove(strategy.buf)
end

-- Test empty deltas mixed with newlines
T["strategy.chat"]["empty deltas with newlines"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      mock.mock_fn_jobstart({
        {
          choices = {
            {
              delta = {
                content = "Line 1\n",
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                content = "",
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                content = "Line 2",
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

T["strategy.chat"]["empty deltas with newlines"]["no extra empty lines between content lines"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)
  eq(
    { "/sia", "", "Line 1", "Line 2" },
    vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  )
  ChatStrategy.remove(strategy.buf)
end

-- Test standalone newline deltas produce exactly the right number of empty lines
T["strategy.chat"]["standalone newline deltas"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      mock.mock_fn_jobstart({
        {
          choices = {
            {
              delta = {
                content = "Before",
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                content = "\n\n",
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                content = "After",
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

T["strategy.chat"]["standalone newline deltas"]["produce exactly one blank line"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new_conversation({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)
  eq(
    { "/sia", "", "Before", "", "After" },
    vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  )
  ChatStrategy.remove(strategy.buf)
end

-- Test StreamRenderer:append("") directly - the lowest level defense
T["strategy.chat"]["StreamRenderer append empty"] = function()
  local StreamRenderer = require("sia.strategy.common").StreamRenderer
  local Canvas = require("sia.canvas").Canvas

  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "existing" })
  vim.bo[buf].modifiable = true

  local canvas = Canvas:new(buf)
  local renderer = StreamRenderer:new({ canvas = canvas, line = 0, column = 8 })

  -- Append empty string should be a no-op
  renderer:append("")
  eq({ "existing" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  eq(0, renderer.line)
  eq(8, renderer.column)

  -- Append real content should work
  renderer:append(" text")
  eq({ "existing text" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

  -- Another empty append should still be a no-op
  renderer:append("")
  eq({ "existing text" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
