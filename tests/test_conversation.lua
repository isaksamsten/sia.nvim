local Conversation = require("sia.conversation").Conversation
local config = require("sia.config")

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function create_tool_call_message(id, name)
  return {
    role = "assistant",
    content = nil,
    tool_calls = {
      {
        id = id,
        type = "function",
        ["function"] = {
          name = name,
          arguments = '{"test": "hello"}',
        },
      },
    },
  }
end

local function create_tool_response_message(id, name, content)
  return {
    role = "tool",
    _tool_call = {
      id = id,
      ["function"] = {
        name = name,
        arguments = '{"test": "hello"}',
      },
    },
    content = content or "success",
  }
end

--- @param messages sia.Message[]
local function count_pruned(messages)
  local count = 0
  for _, msg in ipairs(messages) do
    if msg.content and string.find(msg.content, "pruned") then
      count = count + 1
    end
  end
  return count
end

T["tool call filtering"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      T.original_get_context_config = config.get_context_config
    end,
    post_once = function()
      config.get_context_config = T.original_get_context_config
    end,
  },
})

T["tool call filtering"]["under max limit should not filter"] = function()
  config.get_context_config = function()
    return {
      keep = 3,
      max_tool = 10,
      exclude = {},
    }
  end

  local conv = Conversation:new({ instructions = {} }, nil)

  for i = 1, 5 do
    conv:add_instruction(create_tool_call_message("call_" .. i, "test_tool"))
    conv:add_instruction(create_tool_response_message("call_" .. i, "test_tool"))
  end

  local query = conv:prepare_messages()
  eq(0, count_pruned(query))
end

T["tool call filtering"]["exceeding max should filter to keep most recent"] = function()
  config.get_context_config = function()
    return {
      keep = 3,
      max_tool = 5,
      exclude = {},
      clear_input = true,
    }
  end

  local conv = Conversation:new({ instructions = {} }, nil)

  local context = {
    clear_outdated_tool_input = function(tool)
      local new_tool = vim.deepcopy(tool)
      new_tool["function"].arguments = "pruned"

      return new_tool
    end,
  }
  for i = 1, 7 do
    conv:add_instruction(create_tool_call_message("call_" .. i, "test_tool"), context)
    conv:add_instruction(
      create_tool_response_message("call_" .. i, "test_tool"),
      context
    )
  end

  local messages = conv:prepare_messages()
  eq(4, count_pruned(messages))
  eq("pruned", messages[1].tool_calls[1]["function"].arguments)
  eq("pruned", messages[3].tool_calls[1]["function"].arguments)
  eq("pruned", messages[5].tool_calls[1]["function"].arguments)
  eq("pruned", messages[7].tool_calls[1]["function"].arguments)
  eq('{"test": "hello"}', messages[9].tool_calls[1]["function"].arguments)
end

T["tool call filtering"]["should permanently mark outdated tool calls"] = function()
  config.get_context_config = function()
    return {
      keep = 2,
      max_tool = 3,
      exclude = {},
    }
  end

  local conv = Conversation:new({ instructions = {} }, nil)
  for i = 1, 5 do
    conv:add_instruction(create_tool_call_message("call_" .. i, "test_tool"))
    conv:add_instruction(create_tool_response_message("call_" .. i, "test_tool"))
  end

  local query1 = conv:prepare_messages()
  eq(3, count_pruned(query1))

  conv:add_instruction(create_tool_call_message("call_6", "test_tool"))
  conv:add_instruction(create_tool_response_message("call_6", "test_tool"))

  local query2 = conv:prepare_messages()
  eq(3, count_pruned(query2))
end

T["tool call filtering"]["should respect excluded tools"] = function()
  config.get_context_config = function()
    return {
      keep = 2,
      max_tool = 3,
      exclude = { "important_tool" },
    }
  end

  local conv = Conversation:new({ instructions = {} }, nil)

  conv:add_instruction(create_tool_call_message("call_1", "regular_tool"))
  conv:add_instruction(create_tool_response_message("call_1", "test_tool"))
  conv:add_instruction(create_tool_call_message("call_2", "important_tool"))
  conv:add_instruction(create_tool_response_message("call_2", "test_tool"))
  conv:add_instruction(create_tool_call_message("call_3", "regular_tool"))
  conv:add_instruction(create_tool_response_message("call_3", "test_tool"))
  conv:add_instruction(create_tool_call_message("call_4", "regular_tool"))
  conv:add_instruction(create_tool_response_message("call_4", "test_tool"))

  local query = conv:prepare_messages()

  eq(2, count_pruned(query))
end

T["tool call filtering"]["should handle failed tool calls"] = function()
  config.get_context_config = function()
    return {
      keep = 2,
      max_tool = 3,
      exclude = {},
    }
  end

  local conv = Conversation:new({ instructions = {} }, nil)

  conv:add_instruction(create_tool_call_message("call_1", "test_tool"))
  conv:add_instruction(create_tool_response_message("call_1", "test_tool"))
  conv:add_instruction(create_tool_call_message("call_2", "test_tool"))
  conv:add_instruction(create_tool_response_message("call_2", "test_tool"))

  local failed_msg = create_tool_call_message("call_3", "test_tool")
  failed_msg.kind = "failed"
  conv:add_instruction(failed_msg)

  conv:add_instruction(create_tool_call_message("call_4", "test_tool"))
  conv:add_instruction(create_tool_response_message("call_4", "test_tool"))
  conv:add_instruction(create_tool_call_message("call_5", "test_tool"))
  conv:add_instruction(create_tool_response_message("call_5", "test_tool"))

  local query = conv:prepare_messages()

  eq(2, count_pruned(query))
end

T["tool call filtering"]["add and remove"] = function()
  config.get_context_config = function()
    return {
      keep = 2,
      max_tool = 4,
      exclude = {},
    }
  end

  local conv = Conversation:new({ instructions = {} }, nil)

  for i = 1, 5 do
    conv:add_instruction(create_tool_call_message("call_" .. i, "test_tool"))
    conv:add_instruction(create_tool_response_message("call_" .. i, "test_tool"))
  end

  local query1 = conv:prepare_messages()
  eq(3, count_pruned(query1))

  for i = 6, 8 do
    conv:add_instruction(create_tool_call_message("call_" .. i, "test_tool"))
    conv:add_instruction(create_tool_response_message("call_" .. i, "test_tool"))
  end

  local query2 = conv:prepare_messages()
  eq(6, count_pruned(query2))
end

T["tool call filtering"]["should only trigger when both conditions met"] = function()
  config.get_context_config = function()
    return {
      keep = 3,
      max_tool = 10,
      exclude = {},
    }
  end

  local conv = Conversation:new({ instructions = {} }, nil)

  for i = 1, 5 do
    conv:add_instruction(create_tool_call_message("call_" .. i, "test_tool"))
    conv:add_instruction(create_tool_response_message("call_" .. i, "test_tool"))
  end

  local query = conv:prepare_messages()

  eq(0, count_pruned(query))
end

return T
