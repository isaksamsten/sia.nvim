local assistant = require("sia.assistant")
local mock = require("tests.mock")
local common = require("sia.strategy.common")
local config = require("sia.config")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

-- Minimal conversation stub
local Conversation = {}
Conversation.__index = Conversation
function Conversation:new()
  local Model = require("sia.model")
  return setmetatable({
    _messages = { { role = "user", content = { "hi" }, meta = {} } },
    model = Model.resolve("openai/gpt-4.1-mini"),
    tool_fn = {},
  }, self)
end
function Conversation:get_messages()
  return self._messages
end
function Conversation:last_message()
  return self._messages[#self._messages]
end
function Conversation:prepare_messages()
  return vim.deepcopy(self._messages)
end
function Conversation:add_instruction(msg)
  table.insert(self._messages, msg)
end

-- Test strategy capturing streaming callbacks
local TestStrategy = setmetatable({}, { __index = common.Strategy })
TestStrategy.__index = TestStrategy

function TestStrategy:new()
  local obj = common.Strategy:new(Conversation:new())
  setmetatable(obj, self)
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
function TestStrategy:on_error()
  self.error = true
end
function TestStrategy:on_content(input)
  if input.content then
    table.insert(self.contents, input.content)
  end
  if input.reasoning and input.reasoning.content then
    table.insert(self.reasoning, input.reasoning.content)
  end
  if input.tool_calls then
    self.pending_tools = input.tool_calls
  end
  return true
end
function TestStrategy:on_tools()
  return common.Strategy.on_tools(self)
end
function TestStrategy:on_complete()
  self.completed = true
end

T["assistant.streaming"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      config.options.models["openai/test"] = { "openai", "test-model" }
      config.options.defaults.model = "openai/test"

      mock.mock_fn_jobstart({
        {
          choices = {
            {
              delta = {
                reasoning = "thinking... ",
                content = "Hello",
                tool_calls = {
                  {
                    index = 0,
                    id = "tool_call_id_0",
                    type = "function",
                    ["function"] = { name = "my_", arguments = '{"a":' },
                  },
                },
              },
            },
          },
        },
        {
          choices = {
            {
              delta = {
                tool_calls = {
                  {
                    index = 0,
                    id = "tool_call_id_0",
                    type = "function",
                    ["function"] = { name = "func", arguments = "1}" },
                  },
                },
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

T["assistant.streaming"]["multi field delta processes all fields"] = function()
  local strategy = TestStrategy:new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  eq(true, #strategy.reasoning > 0)
  eq(true, vim.tbl_contains(strategy.contents, "Hello"))
  eq(true, strategy.pending_tools[0] ~= nil)

  local tool = strategy.pending_tools[0]
  eq("my_func", tool["function"].name)
  eq('{"a":1}', tool["function"].arguments)
end

-- Test that partial data split across multiple on_stdout calls is handled correctly
T["assistant.streaming"]["handles partial data across stdout calls"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      mock.mock_fn_jobstart_custom(function(_, job_opts)
        -- Simulate data being split at arbitrary byte boundaries by TCP
        -- Neovim splits by newlines, so each element is a line (without trailing \n)
        -- But when data arrives mid-line, it becomes a partial element
        --
        -- First call: complete line + partial line
        job_opts.on_stdout(1, { 'data: {"choices":[{"delta":{"content":"Hel"}}]}', 'data: {"cho' }, 10)
        -- Second call: rest of partial line + complete line
        job_opts.on_stdout(1, { 'ices":[{"delta":{"content":"lo"}}]}', 'data: {"choices":[{"delta":{"content":"!"}}]}' }, 10)
        -- Final events
        job_opts.on_stdout(
          1,
          { "data: " .. vim.json.encode({ choices = { { delta = {} } }, usage = { total_tokens = 5 } }) },
          10
        )
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
  local strategy = TestStrategy:new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  -- Should have received all three content pieces
  eq(true, vim.tbl_contains(strategy.contents, "Hel"))
  eq(true, vim.tbl_contains(strategy.contents, "lo"))
  eq(true, vim.tbl_contains(strategy.contents, "!"))
end

-- Test that multiple complete events in single stdout call are all processed
T["assistant.streaming"]["handles multiple events in single stdout call"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      mock.mock_fn_jobstart_custom(function(_, job_opts)
        -- Send multiple complete events as separate array elements (how Neovim delivers them)
        job_opts.on_stdout(1, {
          'data: {"choices":[{"delta":{"content":"A"}}]}',
          'data: {"choices":[{"delta":{"content":"B"}}]}',
          'data: {"choices":[{"delta":{"content":"C"}}]}',
        }, 10)
        job_opts.on_stdout(
          1,
          { "data: " .. vim.json.encode({ choices = { { delta = {} } }, usage = { total_tokens = 3 } }) },
          10
        )
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
  local strategy = TestStrategy:new()
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
        job_opts.on_stdout(
          1,
          { "data: " .. vim.json.encode({ choices = { { delta = {} } }, usage = { total_tokens = 5 } }) },
          10
        )
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
  local strategy = TestStrategy:new()
  assistant.execute_strategy(strategy)

  eq(true, strategy.completed)
  eq(nil, strategy.error)
  -- The Responses API format uses different JSON structure, but the test verifies
  -- that event: lines don't corrupt data: line processing
end

return T
