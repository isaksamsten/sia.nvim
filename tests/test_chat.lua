local assistant = require("sia.assistant")
local mock = require("tests.mock")
local config = require("sia.config")
local ChatStrategy = require("sia.strategy").ChatStrategy
local Conversation = require("sia.conversation").Conversation
local tracker = require("sia.tracker")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local defaults = config.options.defaults
local vim_notify = vim.notify
config.get_local_config = function()
  return "mock/model"
end
T["strategy.chat"] = MiniTest.new_set({
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
                if delta.content and delta.content ~= "" then
                  if not strategy:on_content_received({ content = delta.content }) then
                    return true
                  end
                end
                if delta.tool_calls and delta.tool_calls ~= "" then
                  if not strategy:on_tool_call_received(delta.tool_calls) then
                    return true
                  end
                end
              end
            end
          end
        end,
      }
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
  eq(
    { "/sia", "", "Hello World" },
    vim.api.nvim_buf_get_lines(strategy.buf, 0, -1, false)
  )
end

T["strategy.chat"]["simple message"]["test tracking context"] = function()
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, "buffer " .. buf)
  local conversation = Conversation:new({
    instructions = {
      { role = "user", content = "Here's the content of the file" },
    },
  }, { tick = tracker.ensure_tracked(buf), buf = buf })
  local strategy = ChatStrategy:new(conversation, { cmd = "split" })
  assistant.execute_strategy(strategy)

  eq(tracker.user_tick(buf), 0)
  eq(tracker.tracked_buffers[buf].refcount, 1)

  eq(strategy.conversation.messages[1].context.buf, buf)
  eq(strategy.conversation.messages[1]:is_outdated(), false)

  ChatStrategy.remove(strategy.buf)
  eq(tracker.user_tick(buf), 0)
  eq(tracker.tracked_buffers[buf], nil)
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

  vim.api.nvim_buf_delete(strategy.buf, { force = true })

  assistant.execute_strategy(strategy)

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

  local original_on_start = strategy.on_stream_started
  strategy.on_stream_started = function(self)
    -- Delete buffer during on_start to simulate failure
    vim.api.nvim_buf_delete(buf, { force = true })
    return false
  end

  assistant.execute_strategy(strategy)

  -- Should be reset after on_start fails
  eq(strategy.is_busy, false)

  -- Restore original method
  strategy.on_stream_started = original_on_start
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
