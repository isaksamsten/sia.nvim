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
function TestStrategy:on_stream_started()
  return true
end
function TestStrategy:on_error()
  self.error = true
end
function TestStrategy:on_content_received(input)
  if input.content then
    table.insert(self.contents, input.content)
  end
  if input.reasoning and input.reasoning.content then
    table.insert(self.reasoning, input.reasoning.content)
  end
  return true
end
function TestStrategy:on_tool_call_received(calls)
  return common.Strategy.on_tool_call_received(self, calls)
end
function TestStrategy:on_completed()
  self.completed = true
end

T["assistant.streaming"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      config.options.providers.mock = {
        base_url = "mock://provider",
        api_key = function()
          return "test-key"
        end,
        process_response = function(_) end,
        prepare_messages = function(data, _, messages)
          data.messages = vim
            .iter(messages)
            :map(function(m)
              local message = { role = m.role, content = m.content }
              if m._tool_call then
                message.tool_call_id = m._tool_call.id
              end
              if m.tool_calls then
                message.tool_calls = m.tool_calls
              end
              return message
            end)
            :totable()
        end,
        prepare_tools = function(data, tools)
          if tools then
            data.tools = vim
              .iter(tools)
              :map(function(tool)
                return {
                  type = "function",
                  ["function"] = {
                    name = tool.name,
                    description = tool.description,
                    parameters = {
                      type = "object",
                      properties = tool.parameters,
                      required = tool.required,
                      additionalProperties = false,
                    },
                  },
                }
              end)
              :totable()
          end
        end,
        prepare_parameters = function(data, model)
          if data.stream then
            data.stream_options = { include_usage = true }
          end
        end,
        process_usage = function(obj)
          if obj.usage then
            return {
              total = obj.usage.total_tokens or nil,
              prompt = obj.usage.prompt_tokens or nil,
              completion = obj.usage.completion_tokens or nil,
              total_time = 0,
            }
          end
        end,
        process_stream_chunk = function(strategy, obj)
          if obj.choices and #obj.choices > 0 then
            for _, choice in ipairs(obj.choices) do
              local delta = choice.delta
              if delta then
                local reasoning = delta.reasoning or delta.reasoning_content
                if reasoning and reasoning ~= "" then
                  if
                    not strategy:on_content_received({
                      reasoning = { content = reasoning },
                    })
                  then
                    return true
                  end
                end
                if delta.content and delta.content ~= "" then
                  if not strategy:on_content_received({ content = delta.content }) then
                    return true
                  end
                end
                if delta.tool_calls and delta.tool_calls ~= "" then
                  if not strategy:on_tool_call_received(delta.tool_calls) then
                    return true
                  end
                  -- Process tool calls
                  for i, v in ipairs(delta.tool_calls) do
                    local func = v["function"]
                    if v.index == nil then
                      v.index = i
                      v.id = "tool_call_id_" .. v.index
                    end
                    if not strategy.tools[v.index] then
                      strategy.tools[v.index] = {
                        ["function"] = { name = "", arguments = "" },
                        type = v.type,
                        id = v.id,
                      }
                    end
                    if func.name then
                      strategy.tools[v.index]["function"].name = strategy.tools[v.index]["function"].name
                        .. func.name
                    end
                    if func.arguments then
                      strategy.tools[v.index]["function"].arguments = strategy.tools[v.index]["function"].arguments
                        .. func.arguments
                    end
                  end
                end
              end
            end
          end
        end,
      }
      config.options.models["mock/model"] = { "mock", "mock-model" }
      config.options.defaults.model = "mock/model"

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
  eq(true, strategy.tools[0] ~= nil)

  local tool = strategy.tools[0]
  eq("my_func", tool["function"].name)
  eq('{"a":1}', tool["function"].arguments)
end

return T
