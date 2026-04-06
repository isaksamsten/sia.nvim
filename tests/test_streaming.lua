local assistant = require("sia.assistant")
local mock = require("tests.mock")
local common = require("sia.strategy.common")
local config = require("sia.config")
local Conversation = require("sia.conversation")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

--- Create a minimal real conversation for streaming tests
local function make_conversation()
  return Conversation.new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
end

-- Test strategy capturing streaming callbacks
local TestStrategy = setmetatable({}, { __index = common.Strategy })
TestStrategy.__index = TestStrategy

function TestStrategy.new()
  local conversation = make_conversation()
  conversation:add_user_message("hi")
  local obj = common.Strategy.new(conversation)
  setmetatable(obj, TestStrategy)
  obj.cancellable = { is_cancelled = false }
  obj.reasoning = {}
  obj.contents = {}
  return obj
end

function TestStrategy:on_request_start()
  return true
end
function TestStrategy:on_stream_start()
  return true
end
function TestStrategy:on_error(_)
  self.error = true
end
function TestStrategy:on_stream(input)
  if input.content then
    table.insert(self.contents, input.content)
  end
  if input.reasoning and input.reasoning.content then
    table.insert(self.reasoning, input.reasoning.content)
  end
  return true
end
function TestStrategy:on_tools()
  return common.Strategy.on_tools(self)
end
function TestStrategy:on_finish(ctx)
  self.completed = true
  self.finish_ctx = ctx
end

T["assistant.streaming"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      config.options.settings.model = "openai/gpt-4.1"
    end,
  },
})

-- Test that reasoning + content in a single delta are both delivered via on_stream
T["assistant.streaming"]["multi field delta processes reasoning and content"] =
  MiniTest.new_set({
    hooks = {
      pre_case = function()
        mock.mock_fn_jobstart({
          {
            choices = {
              {
                delta = {
                  reasoning = "thinking... ",
                  content = "Hello",
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
      post_case = function()
        mock.unmock_assistant()
      end,
    },
  })

T["assistant.streaming"]["multi field delta processes reasoning and content"]["delivers both fields"] = function()
  local strategy = TestStrategy.new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  eq(true, #strategy.reasoning > 0)
  eq(true, vim.tbl_contains(strategy.contents, "Hello"))
  eq(true, vim.tbl_contains(strategy.contents, " World"))

  -- Verify the assistant message was stored in the conversation
  local entries = strategy.conversation.entries
  local assistant_entry = entries[#entries]
  eq("assistant", assistant_entry.role)
  eq("Hello World", assistant_entry.content)

  -- Verify the finish context was provided
  eq("string", type(strategy.finish_ctx.turn_id))
end

-- Test that partial data split across multiple on_stdout calls is handled correctly
T["assistant.streaming"]["handles partial data across stdout calls"] =
  MiniTest.new_set({
    hooks = {
      pre_case = function()
        mock.mock_fn_jobstart_custom(function(_, job_opts)
          -- Simulate data being split at arbitrary byte boundaries by TCP
          -- Neovim splits by newlines, so each element is a line (without trailing \n)
          -- But when data arrives mid-line, it becomes a partial element
          --
          -- First call: complete line + partial line
          job_opts.on_stdout(
            1,
            { 'data: {"choices":[{"delta":{"content":"Hel"}}]}', 'data: {"cho' },
            10
          )
          -- Second call: rest of partial line + complete line
          job_opts.on_stdout(1, {
            'ices":[{"delta":{"content":"lo"}}]}',
            'data: {"choices":[{"delta":{"content":"!"}}]}',
          }, 10)
          -- Final events
          job_opts.on_stdout(1, {
            "data: " .. vim.json.encode({
              choices = { { delta = {} } },
              usage = { total_tokens = 5 },
            }),
          }, 10)
          job_opts.on_stdout(1, { "data: [DONE]" }, nil)
          job_opts.on_exit(1, 0, nil)
          return 1
        end)
      end,
      post_case = function()
        mock.unmock_assistant()
      end,
    },
  })

T["assistant.streaming"]["handles partial data across stdout calls"]["reconstructs split content"] = function()
  local strategy = TestStrategy.new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  -- Should have received all three content pieces
  eq(true, vim.tbl_contains(strategy.contents, "Hel"))
  eq(true, vim.tbl_contains(strategy.contents, "lo"))
  eq(true, vim.tbl_contains(strategy.contents, "!"))
end

-- Test that multiple complete events in single stdout call are all processed
T["assistant.streaming"]["handles multiple events in single stdout call"] =
  MiniTest.new_set({
    hooks = {
      pre_case = function()
        mock.mock_fn_jobstart_custom(function(_, job_opts)
          -- Send multiple complete events as separate array elements (how Neovim delivers them)
          job_opts.on_stdout(1, {
            'data: {"choices":[{"delta":{"content":"A"}}]}',
            'data: {"choices":[{"delta":{"content":"B"}}]}',
            'data: {"choices":[{"delta":{"content":"C"}}]}',
          }, 10)
          job_opts.on_stdout(1, {
            "data: " .. vim.json.encode({
              choices = { { delta = {} } },
              usage = { total_tokens = 3 },
            }),
          }, 10)
          job_opts.on_stdout(1, { "data: [DONE]" }, nil)
          job_opts.on_exit(1, 0, nil)
          return 1
        end)
      end,
      post_case = function()
        mock.unmock_assistant()
      end,
    },
  })

T["assistant.streaming"]["handles multiple events in single stdout call"]["processes all events"] = function()
  local strategy = TestStrategy.new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  eq(true, vim.tbl_contains(strategy.contents, "A"))
  eq(true, vim.tbl_contains(strategy.contents, "B"))
  eq(true, vim.tbl_contains(strategy.contents, "C"))
end

-- Test that SSE event: lines are properly ignored (used by Responses API)
T["assistant.streaming"]["handles SSE event lines"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      mock.mock_fn_jobstart_custom(function(_, job_opts)
        -- Simulate Responses API format with event: lines
        -- Each SSE event has an "event:" line followed by a "data:" line
        job_opts.on_stdout(1, {
          "event: response.created",
          'data: {"type":"response.created","response":{"id":"123"}}',
          "event: response.output_text.delta",
          'data: {"type":"response.output_text.delta","delta":"Hello"}',
          "event: response.output_text.delta",
          'data: {"type":"response.output_text.delta","delta":" World"}',
        }, 10)
        job_opts.on_stdout(1, {
          "data: " .. vim.json.encode({
            choices = { { delta = {} } },
            usage = { total_tokens = 5 },
          }),
        }, 10)
        job_opts.on_stdout(1, { "data: [DONE]" }, nil)
        job_opts.on_exit(1, 0, nil)
        return 1
      end)
    end,
    post_case = function()
      mock.unmock_assistant()
    end,
  },
})

T["assistant.streaming"]["handles SSE event lines"]["ignores event lines and processes data"] = function()
  local strategy = TestStrategy.new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  -- The Responses API format uses different JSON structure, but the test verifies
  -- that event: lines don't corrupt data: line processing
end

-- Test that SSE comment lines are ignored instead of being buffered into the
-- next data event.
T["assistant.streaming"]["handles SSE comment lines"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      mock.mock_fn_jobstart_custom(function(_, job_opts)
        job_opts.on_stdout(1, {
          ": keep-alive",
          'data: {"choices":[{"delta":{"content":"Hello"}}]}',
          ": ping",
          'data: {"choices":[{"delta":{"content":" World"}}]}',
        }, 10)
        job_opts.on_stdout(1, {
          "data: " .. vim.json.encode({
            choices = { { delta = {} } },
            usage = { total_tokens = 5 },
          }),
        }, 10)
        job_opts.on_stdout(1, { "data: [DONE]" }, nil)
        job_opts.on_exit(1, 0, nil)
        return 1
      end)
    end,
    post_case = function()
      mock.unmock_assistant()
    end,
  },
})

T["assistant.streaming"]["handles SSE comment lines"]["ignores keepalive comments"] = function()
  local strategy = TestStrategy.new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  eq(true, vim.tbl_contains(strategy.contents, "Hello"))
  eq(true, vim.tbl_contains(strategy.contents, " World"))
end

-- Test that empty string content deltas are filtered at the provider level
T["assistant.streaming"]["empty content deltas"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      mock.mock_fn_jobstart_custom(function(_, job_opts)
        -- Simulate empty content deltas interspersed with real content
        job_opts.on_stdout(1, {
          'data: {"choices":[{"delta":{"content":"Hello"}}]}',
          'data: {"choices":[{"delta":{"content":""}}]}',
          'data: {"choices":[{"delta":{"content":" World"}}]}',
        }, 10)
        job_opts.on_stdout(1, {
          "data: " .. vim.json.encode({
            choices = { { delta = {} } },
            usage = { total_tokens = 5 },
          }),
        }, 10)
        job_opts.on_stdout(1, { "data: [DONE]" }, nil)
        job_opts.on_exit(1, 0, nil)
        return 1
      end)
    end,
    post_case = function()
      mock.unmock_assistant()
    end,
  },
})

T["assistant.streaming"]["empty content deltas"]["are filtered by openai provider"] = function()
  local strategy = TestStrategy.new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  -- The empty "" delta should NOT appear in the strategy's contents
  eq(false, vim.tbl_contains(strategy.contents, ""))
  -- Real content should still come through
  eq(true, vim.tbl_contains(strategy.contents, "Hello"))
  eq(true, vim.tbl_contains(strategy.contents, " World"))
end

-- Test empty content deltas between newlines
T["assistant.streaming"]["empty content deltas between newlines"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      mock.mock_fn_jobstart_custom(function(_, job_opts)
        job_opts.on_stdout(1, {
          'data: {"choices":[{"delta":{"content":"Line 1\\n"}}]}',
          'data: {"choices":[{"delta":{"content":""}}]}',
          'data: {"choices":[{"delta":{"content":"Line 2"}}]}',
        }, 10)
        job_opts.on_stdout(1, {
          "data: " .. vim.json.encode({
            choices = { { delta = {} } },
            usage = { total_tokens = 5 },
          }),
        }, 10)
        job_opts.on_stdout(1, { "data: [DONE]" }, nil)
        job_opts.on_exit(1, 0, nil)
        return 1
      end)
    end,
    post_case = function()
      mock.unmock_assistant()
    end,
  },
})

T["assistant.streaming"]["empty content deltas between newlines"]["do not add extra content"] = function()
  local strategy = TestStrategy.new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  eq(false, vim.tbl_contains(strategy.contents, ""))
  eq(true, vim.tbl_contains(strategy.contents, "Line 1\n"))
  eq(true, vim.tbl_contains(strategy.contents, "Line 2"))
end

-- Test that a standalone "\n" delta IS passed through (it's legitimate content)
T["assistant.streaming"]["standalone newline deltas"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      mock.mock_fn_jobstart_custom(function(_, job_opts)
        job_opts.on_stdout(1, {
          'data: {"choices":[{"delta":{"content":"Line 1"}}]}',
          'data: {"choices":[{"delta":{"content":"\\n"}}]}',
          'data: {"choices":[{"delta":{"content":"\\n"}}]}',
          'data: {"choices":[{"delta":{"content":"Line 3"}}]}',
        }, 10)
        job_opts.on_stdout(1, {
          "data: " .. vim.json.encode({
            choices = { { delta = {} } },
            usage = { total_tokens = 5 },
          }),
        }, 10)
        job_opts.on_stdout(1, { "data: [DONE]" }, nil)
        job_opts.on_exit(1, 0, nil)
        return 1
      end)
    end,
    post_case = function()
      mock.unmock_assistant()
    end,
  },
})

T["assistant.streaming"]["standalone newline deltas"]["are passed through as content"] = function()
  local strategy = TestStrategy.new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  -- "\n" is legitimate content and should be passed through
  eq(true, vim.tbl_contains(strategy.contents, "Line 1"))
  eq(true, vim.tbl_contains(strategy.contents, "\n"))
  eq(true, vim.tbl_contains(strategy.contents, "Line 3"))
end

return T
