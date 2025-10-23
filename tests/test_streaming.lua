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
  return setmetatable({
    _messages = { { role = "user", content = { "hi" } } },
    model = "mock/model",
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

return T
