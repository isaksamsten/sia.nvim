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

local function tool_result_ranges(buf)
  local namespace = vim.api.nvim_get_namespaces()["sia_chat_tool_result"]
  if not namespace then
    return {}
  end

  local marks = vim.api.nvim_buf_get_extmarks(buf, namespace, 0, -1, { details = true })
  local ranges = {}
  for _, mark in ipairs(marks) do
    local details = mark[4]
    table.insert(ranges, {
      start = mark[2],
      finish = details.end_line or details.end_row,
      hl_group = details.hl_group,
    })
  end

  table.sort(ranges, function(left, right)
    return left.start < right.start
  end)

  return ranges
end

config.get_local_config = function()
  return nil
end
T["strategy.chat"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      config.options.settings.model = "openai/gpt-4.1"
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
  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)
  local messages = strategy.conversation:serialize()
  eq("Hello World", messages[2].content)
  eq(
    { "Hello World", "" },
    vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  )
end

T["strategy.chat"]["simple message"]["test tracking context"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "buffer " .. buf)
  local conversation = Conversation.new({
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
  local conversation = Conversation.new({
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
  local conversation = Conversation.new({
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

T["strategy.chat"]["pending queries appear immediately and disappear when consumed"] = function()
  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy.is_busy = true
  local function progress()
    local namespace = vim.api.nvim_get_namespaces()["sia_chat_progress"]
    local marks = vim.api.nvim_buf_get_extmarks(strategy.buf, namespace, 0, -1, { details = true })
    return marks[1][4].virt_lines
  end

  strategy:submit({ hidden_messages = { "secret" }, content = "Follow up\nquery" })
  eq({
    { { "⠋ Waiting for model…", "SiaProgress" } },
    { { "  ↳ Follow up query", "SiaUserPending" } },
  }, progress())
  strategy:on_stream({ content = "Working" })
  eq("  ↳ Follow up query", progress()[2][1][1])
  strategy:on_round_end("turn")
  eq(1, #progress())
  strategy:submit({ content = "Another query" })
  eq(2, #progress())
  strategy:on_cancel()
  local namespace = vim.api.nvim_get_namespaces()["sia_chat_progress"]
  eq({}, vim.api.nvim_buf_get_extmarks(strategy.buf, namespace, 0, -1, {}))
  eq(0, conversation:pending_user_message_count())
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
  local conversation = Conversation.new({
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
  local conversation = Conversation.new({
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
  local conversation = Conversation.new({
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
  local conversation = Conversation.new({
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
  local conversation = Conversation.new({
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

  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  assistant.execute_strategy(strategy)

  local expected = {
    "Plan the change",
    "Check the edge cases",
    "Done",
    "",
  }
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  local win = strategy:get_win()
  vim.api.nvim_set_current_win(win)
  eq("expr", vim.wo[win].foldmethod)
  eq("SiaFolded", vim.opt_local.winhighlight:get().Folded)
  vim.opt_local.winhighlight:append({ Normal = "Normal" })
  vim.api.nvim_exec_autocmds("BufWinEnter", { buffer = strategy.buf })
  eq("SiaFolded", vim.opt_local.winhighlight:get().Folded)
  eq("Normal", vim.opt_local.winhighlight:get().Normal)
  eq(1, vim.fn.foldclosed(1))

  strategy:redraw()
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  eq(1, vim.fn.foldclosed(1))

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

  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  assistant.execute_strategy(strategy)

  local expected = {
    "First chunk",
    "Second line",
    "Result",
    "",
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

  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  assistant.execute_strategy(strategy)

  local expected = {
    "I thought about it",
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

  local conversation = Conversation.new({
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
      arguments = '{"command":"make test"}',
    },
    "test output",
    {
      summary = {
        header = "Ran make test",
        detail = { text = "Last lines:\n- 120 passed\n- 2 skipped" },
      },
    }
  )
  conversation:add_assistant_message(turn_id, "All good")

  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  local expected = {
    "Plan the check",
    "• Ran make test",
    "  + Details",
    "```text",
    "Last lines:",
    "- 120 passed",
    "- 2 skipped",
    "```",
    "All good",
    "",
  }

  strategy:redraw()
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  eq({
    {
      start = 1,
      finish = 2,
      hl_group = "SiaToolResult",
    },
  }, tool_result_ranges(strategy.buf))

  local win = strategy:get_win()
  vim.api.nvim_set_current_win(win)
  eq(3, vim.fn.foldclosed(3))

  strategy:redraw()
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  eq({
    {
      start = 1,
      finish = 2,
      hl_group = "SiaToolResult",
    },
  }, tool_result_ranges(strategy.buf))
  eq(3, vim.fn.foldclosed(3))

  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["tool summaries render inline while running and hide when completed without summary"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new({
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
    "Plan the check",
    "• Running bash: make test",
    "",
  }, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  eq({
    {
      start = 1,
      finish = 2,
      hl_group = "SiaToolResult",
    },
  }, tool_result_ranges(strategy.buf))

  strategy:on_tool_results({
    {
      key = "tool-1",
      index = 1,
      name = "bash",
      summary = {
        header = "Ran bash: make test",
        detail = { text = "Tests passed" },
      },
      status = "done",
      actions = {},
      verification = {
        level = "low",
        action = "run tests",
        matches_approved_action = false,
        reason = "Only runs the test suite",
      },
    },
  })

  eq(
    false,
    vim
      .iter(vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
      :any(function(line)
        return line
          == ">! Automatically verified (low risk): Only runs the test suite"
      end)
  )

  strategy:on_tool_status({
    {
      key = "tool-1",
      index = 1,
      name = "bash",
      summary = {
        header = "Running bash: make test",
        detail = { text = "ignored until done" },
      },
      status = "running",
    },
  })

  eq({
    {
      start = 1,
      finish = 2,
      hl_group = "SiaToolResult",
    },
  }, tool_result_ranges(strategy.buf))

  strategy:on_tool_results({
    {
      key = "tool-1",
      index = 1,
      name = "bash",
      summary = nil,
      status = "done",
      actions = {},
    },
  })

  eq({
    "Plan the check",
    "",
  }, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  eq({}, tool_result_ranges(strategy.buf))

  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["hidden tools restore spacing and allow subsequent tool rendering"] = function()
  local conversation = Conversation.new({ model = require("sia.model").resolve("openai/gpt-4.1") })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:on_request_start()
  strategy:on_stream_start()
  strategy.turn_renderer:append_content("Before")
  local before = vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  strategy:on_tool_results({ { key = "hidden", status = "done", actions = {} } })
  eq(before, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  for i = 1, 2 do
    local key = "failed-" .. i
    strategy:on_tool_status({ { key = key, status = "running", summary = "Editing" } })
    strategy:on_tool_results({ { key = key, status = "done", actions = {} } })
    eq(before, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
    eq({}, tool_result_ranges(strategy.buf))
  end
  strategy:on_tool_results({ { key = "success", status = "done", summary = "Edited file", actions = {} } })
  eq(1, #tool_result_ranges(strategy.buf))
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["redraw skips persisted tool entries without summary"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new({
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
      arguments = '{"command":"make test"}',
    },
    "test output",
    {
      summary = nil,
    }
  )
  conversation:add_assistant_message(turn_id, "All good")

  local strategy = ChatStrategy.new(conversation, { cmd = "split" })

  strategy:redraw()
  eq({
    "Plan the check",
    "All good",
    "",
  }, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  eq({}, tool_result_ranges(strategy.buf))

  strategy:redraw()
  eq({
    "Plan the check",
    "All good",
    "",
  }, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  eq({}, tool_result_ranges(strategy.buf))

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
          job_opts.on_stdout(1, { "data: " .. vim.json.encode(datum), "" }, 10)
        end
      end
      job_opts.on_stdout(1, {
        "data: " .. vim.json.encode({
          choices = { { delta = {} } },
          usage = { total_tokens = 10 * call_count },
        }),
        "",
      }, 10)
      job_opts.on_stdout(1, { "data: [DONE]", "" }, nil)
      job_opts.on_exit(1, 0, nil)
      return 1
    end)

    local source_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, source_buf)

    local conversation = Conversation.new({
      model = require("sia.model").resolve("openai/gpt-4.1"),
    })
    conversation:add_system_message("Ok")

    conversation.tool_implementation["test_tool"] = {
      summary = function() return "test_tool" end,
      execute = function(_args, callback, _opts)
        callback({ content = "tool result", summary = false })
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
    "Let me check",
    "Now I know",
    "The answer",
    "",
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
            job_opts.on_stdout(1, { "data: " .. vim.json.encode(datum), "" }, 10)
          end
        end
        job_opts.on_stdout(1, {
          "data: " .. vim.json.encode({
            choices = { { delta = {} } },
            usage = { total_tokens = 10 * call_count },
          }),
          "",
        }, 10)
        job_opts.on_stdout(1, { "data: [DONE]", "" }, nil)
        job_opts.on_exit(1, 0, nil)
        return 1
      end)

      local source_buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_win_set_buf(0, source_buf)

      local conversation = Conversation.new({
        model = require("sia.model").resolve("openai/gpt-4.1"),
      })
      conversation:add_system_message("Ok")

      conversation.tool_implementation["test_tool"] = {
        summary = function() return "test_tool" end,
        execute = function(_args, callback, _opts)
          callback({ content = "tool result", summary = false })
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
    "First thought",
    "First content",
    "",
    "Second thought",
    "Second content",
    "",
  }
  eq(expected, lines)
end

T["strategy.chat"]["multi-turn reasoning"]["tool-only round has matching streaming and redraw layout"] = function()
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
          job_opts.on_stdout(1, { "data: " .. vim.json.encode(datum), "" }, 10)
        end
      end
      job_opts.on_stdout(1, {
        "data: " .. vim.json.encode({
          choices = { { delta = {} } },
          usage = { total_tokens = 10 * call_count },
        }),
        "",
      }, 10)
      job_opts.on_stdout(1, { "data: [DONE]", "" }, nil)
      job_opts.on_exit(1, 0, nil)
      return 1
    end)

    local source_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_win_set_buf(0, source_buf)

    local conversation = Conversation.new({
      model = require("sia.model").resolve("openai/gpt-4.1"),
    })
    conversation:add_system_message("Ok")

    conversation.tool_implementation["test_tool"] = {
      summary = function() return "test_tool" end,
      execute = function(_args, callback, _opts)
        callback({ content = "tool result", summary = false })
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
    "The answer",
    "",
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

T["strategy.chat"]["tool-only round renders content and footer on redraw"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new({
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
      arguments = '{"command":"ls"}',
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
    "• Ran ls",
    "Here are the files",
    "",
  }
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  -- Verify redraw is idempotent
  strategy:redraw()
  eq(expected, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))

  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["tool-only round with multiple tools has one footer"] = function()
  local source_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, source_buf)

  local conversation = Conversation.new({
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
    arguments = '{"command":"ls"}',
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
    "• Ran ls",
    "• Searched for hello",
    "Found it",
    "",
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

  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)
  eq(
    { "Hello World", "" },
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

  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)
  eq(
    { "Line 1", "Line 2", "" },
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

  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)
  eq(
    { "Before", "", "After", "" },
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

T["strategy.chat"]["partial tool updates preserve earlier tools and their highlights"] = function()
  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:on_request_start()
  strategy:on_stream_start()
  strategy:on_tool_status({ { key = "one", status = "done", summary = "First tool" } })
  strategy:on_tool_status({ { key = "two", status = "running", summary = "Second tool" } })
  local lines = vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  eq({ "• First tool", "• Second tool", "" }, vim.list_slice(lines, #lines - 2))
  eq(2, #tool_result_ranges(strategy.buf))
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["fenced previews keep folds separate and survive redraw"] = function()
  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local turn = conversation:new_turn()
  local summary = {
    header = "Edited file",
    detail = { text = "--- orig/file\n+++ ai/file\n@@ -1 +1 @@\n-old\n+new", ft = "diff" },
  }
  local second = { header = "Ran check", detail = { text = "one" } }
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:on_request_start()
  strategy:on_stream_start()
  local statuses = {
    { key = "edit", status = "done", summary = summary },
    { key = "bash", status = "done", summary = second },
  }
  local function check()
    local lines = vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
    local first, next_tool
    for row, line in ipairs(lines) do
      if line == "```diff" then first = row - 1 end
      if line == "• Ran check" then next_tool = row end
    end
    eq("```", lines[next_tool - 1])
    local foldexpr = require("sia.canvas").foldexpr
    eq(">1", foldexpr(first))
    eq(1, foldexpr(first + 3))
    eq(1, foldexpr(first + 4))
    eq(1, foldexpr(first + 6))
    eq(1, foldexpr(next_tool - 1))
    eq(0, foldexpr(next_tool))
    eq(first, vim.fn.foldclosed(first))
    eq(next_tool - 1, vim.fn.foldclosedend(first))
    eq(-1, vim.fn.foldclosed(next_tool))
    eq(next_tool + 1, vim.fn.foldclosed(next_tool + 1))
    vim.api.nvim_win_set_cursor(0, { next_tool + 1, 0 })
    vim.cmd("normal! zo")
    eq("• Ran check", vim.fn.getline(next_tool))
    eq(-1, vim.fn.foldclosed(next_tool + 1))
    vim.cmd("normal! zc")
  end
  strategy:on_tool_status(statuses)
  check()
  strategy:on_tool_status(statuses)
  check()
  for index, item in ipairs(statuses) do
    conversation:add_tool_message(turn, {
      key = item.key, id = item.key, call_id = item.key, type = "function", name = "edit", arguments = "{}",
    }, "Done", { summary = item.summary })
  end
  strategy:redraw()
  check()
  strategy:redraw()
  check()
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["updating adjacent tool blocks preserves preceding preview folds"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  local canvas = require("sia.canvas").Canvas:new(buf)
  local first = { status = "done", summary = { header = "First", detail = { text = "first output" } } }
  local second = { status = "done", summary = { header = "Second", detail = { text = "second output" } } }
  canvas:update_tool_block({ 0, 0 }, 1, { first = first }, { "first" })
  local function check()
    local ns = vim.api.nvim_get_namespaces().sia_chat_tool_preview
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    eq(2, #marks)
    eq({ 1, 5 }, { marks[1][2], marks[1][4].end_row })
    eq({ 6, 10 }, { marks[2][2], marks[2][4].end_row })
    local expr = require("sia.canvas").foldexpr
    eq(">1", expr(2))
    eq(1, expr(4))
    eq(0, expr(6))
    eq(">1", expr(7))
  end
  local count = canvas:update_tool_block({ 5, 0 }, 1, { second = second }, { "second" })
  check()
  canvas:update_tool_block({ 5, 0 }, count, { second = second }, { "second" })
  check()
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["strategy.chat"]["literal fences and metadata prefixes stay inside previews"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  local canvas = require("sia.canvas").Canvas:new(buf)
  canvas:update_tool_block({ 0, 0 }, 1, {
    tool = { status = "done", summary = { header = "Ran command", detail = { text = "```lua\n>| literal\n```\nend" } } },
  }, { "tool" })
  eq({ "• Ran command", "  + Details", "````text", "```lua", ">| literal", "```", "end", "````", "" },
    vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  -- Metadata-looking text in the fenced body must not create a reasoning fold.
  eq(1, require("sia.canvas").foldexpr(4))
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["strategy.chat"]["multiple detail sections share a fold and retain their fences on redraw"] = function()
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
  local conversation = Conversation.new({ model = require("sia.model").resolve("openai/gpt-4.1") })
  conversation:add_system_message("Ok")
  local turn = conversation:new_turn()
  local summary = { header = "Ran script…", detail = {
    { text = "echo hello\necho world", ft = "bash" },
    { text = "```lua\nhello\n```", ft = "text" },
  } }
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:on_request_start()
  strategy:on_stream_start()
  strategy:on_tool_status({ { key = "bash", status = "done", summary = summary } })
  local function check()
    local lines = vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
    local first
    for i, line in ipairs(lines) do if line == "• Ran script…" then first = i end end
    eq({ "• Ran script…", "  + Details", "```bash", "echo hello", "echo world", "```", "",
      "````text", "```lua", "hello", "```", "````" }, vim.list_slice(lines, first, first + 11))
    eq(first + 1, vim.fn.foldclosed(first + 1))
    eq(first + 11, vim.fn.foldclosedend(first + 1))
    eq(true, vim.fn.foldtextresult(first + 1):find("5 lines", 1, true) ~= nil)
  end
  check()
  conversation:add_tool_message(turn, {
    key = "bash", id = "bash", call_id = "bash", type = "function", name = "bash", arguments = "{}",
  }, "model payload", { summary = summary })
  strategy:redraw()
  check()
  strategy:redraw()
  check()
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["tools in consecutive streams use the same compact spacing as batched tools"] = function()
  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:on_request_start()
  strategy:on_stream_start()
  strategy:on_tool_status({ { key = "first", status = "done", summary = "Ran first" } })
  strategy:on_stream_start()
  strategy:on_tool_status({ { key = "second", status = "done", summary = "Ran second" } })
  local lines = vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  eq({ "• Ran first", "• Ran second", "" }, vim.list_slice(lines, #lines - 2))
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["reasoning folds track plain Markdown through edits and redraw"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].filetype = "sia"
  local canvas = require("sia.canvas").Canvas:new(buf)
  local entries = {
    { role = "assistant", reasoning = { text = "Consider **the intent** carefully\nThen check `code`" }, content = "The answer." },
  }
  canvas:render_messages(entries)
  local function check(start)
    eq(start, vim.fn.foldclosed(start))
    eq(start + 1, vim.fn.foldclosedend(start))
    eq("· Consider the intent carefully · 2 lines", vim.fn.foldtextresult(start))
    eq(0, require("sia.canvas").foldexpr(start + 2))
    eq(0, require("sia.canvas").foldexpr(start + 3))
  end
  eq("Consider **the intent** carefully", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  check(1)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "An earlier message.", "" })
  canvas:refresh_folds()
  check(3)
  canvas:clear()
  canvas:render_messages(entries)
  check(1)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("normal! zo")
  eq(-1, vim.fn.foldclosed(1))
  eq("Consider **the intent** carefully", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  canvas:clear()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ">| ordinary answer text", "Another line" })
  canvas:refresh_folds()
  eq(0, require("sia.canvas").foldexpr(1))
  eq(0, require("sia.canvas").foldexpr(2))
end

T["strategy.chat"]["collapsed reasoning displays inline Markdown with its formatting"] = function()
  local screen = MiniTest.new_child_neovim()
  screen.start({ "-u", "assets/minimal.lua", "-i", "NONE", "-n" })
  local ok, err = pcall(function()
    screen.lua([[
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        "Consider **intent** carefully", "Then check the code", "", "The answer.",
      })
      require("sia.canvas").Canvas:new(buf):mark_reasoning(0, 2)
      vim.api.nvim_set_hl(0, "SiaFolded", { fg = "#abcdef", italic = true })
      vim.api.nvim_set_hl(0, "SiaReasoning", { bg = "#102030" })
      vim.api.nvim_set_hl(0, "@markup.strong.markdown_inline", { bold = true })
      vim.treesitter.start(buf, "markdown")
      vim.wo.foldmethod = "expr"
      vim.wo.foldexpr = "v:lua.require'sia.canvas'.foldexpr(v:lnum)"
      vim.wo.foldtext = "v:lua.require'sia.ui.foldtext'.foldtext()"
      vim.wo.foldlevel = 0
      vim.wo.number = false
      vim.wo.relativenumber = false
      vim.wo.signcolumn = "no"
      vim.wo.foldcolumn = "0"
      vim.cmd("redraw!")
    ]])
    local shot = screen.get_screenshot()
    local line = table.concat(shot.text[1])
    local first = line:find("Consider intent carefully", 1, true)
    eq(true, first ~= nil)
    eq(nil, line:find("**", 1, true))
    eq(2, select(2, line:gsub("· ", "")))
    eq(false, shot.attr[1][first] == shot.attr[1][first + 9])
    eq(1, screen.lua_get("vim.fn.foldclosed(1)"))
    screen.lua("vim.api.nvim_win_set_cursor(0, { 1, 0 }); vim.cmd('normal! zo'); vim.cmd('redraw!')")
    local expanded = screen.get_screenshot()
    eq(1, select(2, table.concat(expanded.text[1]):gsub("· ", "")))
    local intent = table.concat(expanded.text[1]):find("intent", 1, true)
    eq(false, expanded.attr[1][1] == expanded.attr[1][intent])
    -- Background extends through the unused columns and ends with the range.
    eq(false, expanded.attr[2][60] == expanded.attr[3][60])
    eq(expanded.attr[3][60], expanded.attr[4][60])
  end)
  screen.stop()
  assert(ok, err)
end

T["strategy.chat"]["fold text explicitly highlights reasoning and output despite window remapping"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  vim.bo[buf].filetype = "sia"
  local canvas = require("sia.canvas").Canvas:new(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "Think through it", "Check the result", "", "• Ran check",
    "  + Details", "```text", "first", "second", "```", "",
  })
  canvas:mark_reasoning(0, 2)
  canvas:highlight_tool(3, 9, { header = "Ran check", detail = { text = "first\nsecond" } })
  -- Window options can replace the mapping originally installed by ftplugin.
  vim.wo.winhighlight = "Folded:ErrorMsg"
  local observed
  _G.SiaTestFoldtext = function()
    observed = require("sia.ui.foldtext").foldtext()
    return observed
  end
  vim.wo.foldtext = "v:lua.SiaTestFoldtext()"
  canvas:refresh_folds()
  local ok, err = pcall(function()
    vim.fn.foldtextresult(1)
    eq({ { "· ", { "SiaAssistantMarker", "SiaReasoning" } }, { "Think through it · 2 lines", { "SiaFolded", "SiaReasoning" } } }, observed)
    observed = nil
    vim.wo.conceallevel = 3
    eq(3, vim.wo.conceallevel)
    eq(true, vim.fn.foldtextresult(5):find("Show details", 1, true) ~= nil)
    eq({ { "  + Show details… · 2 lines", "SiaFolded" } }, observed)
  end)
  _G.SiaTestFoldtext = nil
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
end

T["strategy.chat"]["details fold stays visible when Markdown fences conceal whole lines"] = function()
  local screen = MiniTest.new_child_neovim()
  screen.start({ "-u", "assets/minimal.lua", "-i", "NONE", "-n" })
  local ok, err = pcall(function()
    screen.lua([[
      local canvas = require("sia.canvas").Canvas:new(vim.api.nvim_get_current_buf())
      canvas:update_tool_block({ 0, 0 }, 1, {
        tool = { status = "done", summary = { header = "Ran check", detail = { text = "output" } } },
      }, { "tool" })
      vim.wo.foldmethod = "expr"
      vim.wo.foldexpr = "v:lua.require'sia.canvas'.foldexpr(v:lnum)"
      vim.wo.foldtext = "v:lua.require'sia.ui.foldtext'.foldtext()"
      vim.wo.foldlevel = 0
      vim.wo.concealcursor = "n"
      local ns = vim.api.nvim_create_namespace("test_concealed_fences")
      for _, row in ipairs({ 2, 4 }) do
        vim.api.nvim_buf_set_extmark(0, ns, row, 0, { end_row = row + 1, conceal_lines = "" })
      end
      canvas:refresh_folds()
    ]])
    for _, level in ipairs({ 2, 3 }) do
      screen.lua("vim.wo.conceallevel = " .. level .. "; vim.cmd('redraw!')")
      local shot = screen.get_screenshot()
      eq(true, table.concat(shot.text[2]):find("+ Show details… · 1 line", 1, true) ~= nil)
      eq(2, screen.lua_get("vim.fn.foldclosed(2)"))
      eq(5, screen.lua_get("vim.fn.foldclosedend(2)"))
    end
  end)
  screen.stop()
  assert(ok, err)
end

local function assistant_markers(buf)
  local ns = vim.api.nvim_get_namespaces()["sia_chat_assistant_text"]
  return vim.tbl_map(function(mark)
    return {
      line = vim.api.nvim_buf_get_lines(buf, mark[2], mark[2] + 1, false)[1],
      text = mark[4].virt_text,
      position = mark[4].virt_text_pos,
    }
  end, vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true }))
end

T["strategy.chat"]["assistant marker appears once while streaming and follows late reasoning"] = function()
  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:on_request_start()
  strategy:on_stream_start()
  strategy:on_stream({ content = "\n" })
  eq({}, assistant_markers(strategy.buf))
  strategy:on_stream({ content = "# Heading" })
  strategy:on_stream({ content = "\nMore text" })
  strategy:on_stream({ reasoning = { content = "Late reasoning" } })
  eq({ {
    line = "# Heading",
    text = { { "· ", "SiaAssistantMarker" } },
    position = "inline",
  } }, assistant_markers(strategy.buf))
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["assistant marker survives tools before and after streamed prose"] = function()
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
  local conversation = Conversation.new({ model = require("sia.model").resolve("openai/gpt-4.1") })
  conversation:add_system_message("Ok")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:on_request_start()
  strategy:on_stream_start()
  strategy:on_tool_results({ {
    key = "search", name = "grep", status = "done", actions = {},
    summary = { header = "Searched for pattern in file", detail = { text = "matching line" } },
  } })
  strategy:on_stream_start()
  strategy:on_stream({ content = "I'll hide failed file-read and search summaries." })
  eq({ "I'll hide failed file-read and search summaries." }, vim.tbl_map(function(mark) return mark.line end,
    assistant_markers(strategy.buf)))
  for _ = 1, 2 do
    strategy:on_tool_status({ { key = "edit", name = "edit", status = "running", summary = "Editing file..." } })
    strategy:on_tool_status({ { key = "edit", name = "edit", status = "running", summary = false } })
    eq({ "I'll hide failed file-read and search summaries." }, vim.tbl_map(function(mark) return mark.line end,
      assistant_markers(strategy.buf)))
  end
  strategy:on_tool_results({ {
    key = "edit", name = "edit", status = "done", actions = {},
    summary = { header = "Edited file", detail = { text = "-old\n+new", ft = "diff" } },
  } })
  eq({ "I'll hide failed file-read and search summaries." }, vim.tbl_map(function(mark) return mark.line end,
    assistant_markers(strategy.buf)))
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["redraw marks assistant blocks but not user messages or tool summaries"] = function()
  local conversation = Conversation.new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  conversation:add_system_message("Ok")
  conversation:add_user_message("User text")
  local turn = conversation:new_turn()
  conversation:add_assistant_message(turn, "# Plan\nCheck file")
  conversation:add_tool_message(turn, {
    key = "view", id = "view", call_id = "view", type = "function", name = "view", arguments = "{}",
  }, "Contents", { summary = "Read file" })
  conversation:add_assistant_message(turn, "The file contains code.\n```lua\nreturn 42\n```")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  for _ = 1, 2 do
    strategy:redraw()
    eq({ "# Plan", "The file contains code." }, vim.tbl_map(function(mark) return mark.line end,
      assistant_markers(strategy.buf)))
  end
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["assistant dot renders smaller beside tool bullets without changing copied text"] = function()
  local screen = MiniTest.new_child_neovim()
  screen.start({ "-u", "assets/minimal.lua", "-i", "NONE", "-n" })
  local ok, err = pcall(function()
    screen.lua([[
      local buf = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "• Read file", "The file contains code." })
      require("sia.canvas").Canvas:new(buf):mark_assistant_text(1)
    ]])
    local shot = screen.get_screenshot()
    eq(true, table.concat(shot.text[1]):find("• Read file", 1, true) ~= nil)
    eq(true, table.concat(shot.text[2]):find("· The file contains code.", 1, true) ~= nil)
    eq("The file contains code.", screen.api.nvim_buf_get_lines(0, 1, 2, false)[1])
  end)
  screen.stop()
  assert(ok, err)
end

T["strategy.chat"]["query blocks and footers keep metadata through redraw without duplicate labels"] = function()
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
  local conversation = Conversation.new({ model = require("sia.model").resolve("openai/gpt-4.1") })
  conversation:add_system_message("Ok")
  conversation:add_user_message("Explain the file.\nKeep it brief.")
  local turn = conversation:new_turn()
  conversation:add_tool_message(turn, {
    key = "read", id = "read", call_id = "read", type = "function", name = "view", arguments = "{}",
  }, "Contents", { summary = "Read file" })
  conversation:add_assistant_message(turn, "The file contains code.")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:redraw()
  local footer_ns = vim.api.nvim_get_namespaces()["sia_chat"]
  local initial_footer = vim.api.nvim_buf_get_extmark_by_id(
    strategy.buf, footer_ns, strategy.canvas.footer_marks[turn], { details = true }
  )
  eq({ { "  #" .. turn:sub(1, 6), "SiaStatus" } }, initial_footer[3].virt_text)
  strategy.canvas:update_assistant_footer(nil, {
    model = conversation.model.name, turn_id = turn, usage = { total_time = 2.4 },
  })
  local ns = vim.api.nvim_get_namespaces()["sia_chat"]
  for _ = 1, 2 do
    local marks = vim.api.nvim_buf_get_extmarks(strategy.buf, ns, 0, -1, { details = true })
    local queries, footers, ranges = {}, {}, {}
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details.hl_group == "SiaUser" then table.insert(ranges, mark) end
      if details.virt_text and details.virt_text[1][1] == "> " then
        table.insert(queries, mark[2])
      elseif details.virt_text then
        table.insert(footers, mark)
      end
    end
    eq({ 0, 1 }, queries)
    eq(1, #ranges)
    eq(2, ranges[1][4].end_row)
    eq(1, #footers)
    eq({
      { "  Worked for 2s", "SiaUsage" },
      { " · #" .. turn:sub(1, 6), "SiaStatus" },
    }, footers[1][4].virt_text)
    eq(vim.api.nvim_buf_line_count(strategy.buf) - 1, footers[1][2])
    eq({ "Explain the file.", "Keep it brief.", "", "• Read file", "The file contains code.", "" },
      vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
    strategy:redraw()
  end
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["consecutive Responses summary parts keep their spacing on redraw"] = function()
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
  local conversation = Conversation.new({ model = require("sia.model").resolve("openai/gpt-5.2") })
  conversation:add_system_message("Ok")
  conversation:add_user_message("Question")
  local turn = conversation:new_turn()
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy.has_generated_name = true
  strategy:on_request_start()
  strategy:on_stream_start()
  local stream = require("sia.provider.openai").responses.new_stream(strategy)
  local parts = {
    "**First section**\n\nCheck the intent.",
    "**Second section**\n\nCheck the context.",
  }
  for index, part in ipairs(parts) do
    stream:process_stream_chunk({ type = "response.reasoning_summary_text.done", item_id = "rs_1", summary_index = index - 1, text = part })
  end
  stream:process_stream_chunk({ type = "response.output_item.done", item = {
    type = "reasoning", id = "rs_1", encrypted_content = "opaque",
    summary = { { type = "summary_text", text = parts[1] }, { type = "summary_text", text = parts[2] } },
  } })
  stream:process_stream_chunk({ type = "response.output_text.delta", delta = "Answer" })
  local result = stream:finalize()
  conversation:add_assistant_message(turn, result.content, result.reasoning)
  strategy:on_finish({ turn_id = turn, usage = {} })
  local streamed = vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  eq(true, table.concat(streamed, "\n"):find(parts[1] .. "\n\n" .. parts[2], 1, true) ~= nil)
  strategy:redraw()
  eq(streamed, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["conversation naming uses the summarize role model"] = function()
  local old_model = config._raw_options.settings.model
  local old_fetch = assistant.fetch_response
  config.options.settings.model = {
    default = "openai/gpt-4.1",
    summarize = "openai/gpt-5.2",
  }
  local captured_model
  assistant.fetch_response = function(conversation)
    captured_model = conversation.model.name
  end
  local ok, err = pcall(function()
    vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
    local conversation = Conversation.new({ model = require("sia.model").resolve("openai/gpt-4.1") })
    conversation:add_user_message("Question")
    local turn = conversation:new_turn()
    local strategy = ChatStrategy.new(conversation, { cmd = "split" })
    strategy:on_request_start()
    strategy:on_stream_start()
    strategy:on_stream({ content = "Answer" })
    conversation:add_assistant_message(turn, "Answer")
    strategy:on_finish({ turn_id = turn, usage = {} })
    eq("openai/gpt-5.2", captured_model)
  end)
  config.options.settings.model = old_model
  assistant.fetch_response = old_fetch
  if not ok then error(err) end
end

T["strategy.chat"]["completed streaming metadata matches its redrawn footer"] = function()
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
  local conversation = Conversation.new({ model = require("sia.model").resolve("openai/gpt-4.1") })
  conversation:add_system_message("Ok")
  conversation:add_user_message("Question")
  local turn = conversation:new_turn()
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy.has_generated_name = true
  strategy:on_request_start()
  strategy:on_stream_start()
  strategy:on_stream({ content = "Answer" })
  conversation:add_assistant_message(turn, "Answer")
  strategy:on_finish({ turn_id = turn, usage = { total_time = 1.5 } })
  local ns = vim.api.nvim_get_namespaces()["sia_chat"]
  local function footer()
    local mark = vim.api.nvim_buf_get_extmark_by_id(strategy.buf, ns, strategy.canvas.footer_marks[turn], { details = true })
    return { row = mark[1], text = mark[3].virt_text }
  end
  local live = footer()
  eq({
    { "  Worked for 2s", "SiaUsage" },
    { " · #" .. turn:sub(1, 6), "SiaStatus" },
  }, live.text)
  local lines = vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  strategy:redraw()
  eq(live, footer())
  eq(lines, vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false))
  ChatStrategy.remove(strategy.buf)
end

T["strategy.chat"]["query markers and footer are visible without role header bars"] = function()
  local screen = MiniTest.new_child_neovim()
  screen.start({ "-u", "assets/minimal.lua", "-i", "NONE", "-n" })
  local ok, err = pcall(function()
    screen.lua([[
      local conversation = require("sia.conversation").new({ model = require("sia.model").resolve("openai/gpt-4.1") })
      conversation:add_system_message("Ok")
      conversation:add_user_message("Explain this file.")
      local turn = conversation:new_turn()
      conversation:add_assistant_message(turn, "The file contains code.")
      local strategy = require("sia.strategy").ChatStrategy.new(conversation, { cmd = "enew" })
      strategy:redraw()
      strategy.canvas:update_assistant_footer(nil, { model = "model", turn_id = turn, usage = { total_time = 2.4 } })
    ]])
    local shot = screen.get_screenshot()
    local text = table.concat(vim.tbl_map(function(row) return table.concat(row) end, shot.text), "\n")
    eq(true, text:find("> Explain this file.", 1, true) ~= nil)
    eq(true, text:find("· The file contains code.", 1, true) ~= nil)
    eq(true, text:find("Worked for 2s · #", 1, true) ~= nil)
    eq(nil, text:find("/sia", 1, true))
    eq(nil, text:find("/you", 1, true))
  end)
  screen.stop()
  assert(ok, err)
end

T["strategy.chat"]["new queries preserve existing footers even after trailing blank lines"] = function()
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(true, false))
  local conversation = Conversation.new({ model = require("sia.model").resolve("openai/gpt-4.1") })
  conversation:add_system_message("Ok")
  conversation:add_user_message("First question")
  local turn = conversation:new_turn()
  conversation:add_assistant_message(turn, "First answer\n\n")
  local strategy = ChatStrategy.new(conversation, { cmd = "split" })
  strategy:redraw()
  local ns = vim.api.nvim_get_namespaces()["sia_chat"]
  local mark = strategy.canvas.footer_marks[turn]
  local before = vim.api.nvim_buf_get_extmark_by_id(strategy.buf, ns, mark, {})
  conversation:add_user_message("Second question")
  strategy.canvas:render_messages({ conversation:get_last_entry() }, conversation.model.name)
  eq(before, vim.api.nvim_buf_get_extmark_by_id(strategy.buf, ns, mark, {}))
  eq("", vim.api.nvim_buf_get_lines(strategy.buf, before[1], before[1] + 1, false)[1])
  local last = vim.api.nvim_buf_line_count(strategy.buf) - 1
  eq(true, last > before[1] + 1)
  eq("Second question", vim.api.nvim_buf_get_lines(strategy.buf, last, last + 1, false)[1])
  ChatStrategy.remove(strategy.buf)
end

return T
