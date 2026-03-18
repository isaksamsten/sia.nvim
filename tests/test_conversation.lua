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
      T.original_get_local_config = config.get_local_config
    end,
    post_once = function()
      config.get_local_config = T.original_get_local_config
    end,
  },
})

T["tool call filtering"]["under max limit should not filter"] = function()
  config.get_local_config = function()
    return {
      context = {
        keep = 3,
        max_tool = 10,
        exclude = {},
      },
    }
  end

  local conv = require("sia.conversation").new_conversation({ temporary = true })

  for i = 1, 5 do
    conv:add_instruction(create_tool_call_message("call_" .. i, "test_tool"))
    conv:add_instruction(create_tool_response_message("call_" .. i, "test_tool"))
  end

  local query = conv:prepare_messages()
  eq(0, count_pruned(query))
end

T["tool call filtering"]["exceeding max should filter to keep most recent"] = function()
  config.get_local_config = function()
    return {
      context = {
        keep = 3,
        max_tool = 5,
        exclude = {},
        clear_input = true,
      },
    }
  end

  local conv = require("sia.conversation").new_conversation({ temporary = true })

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
  eq(3, count_pruned(messages))
  eq("pruned", messages[1].tool_calls[1]["function"].arguments)
  eq("pruned", messages[3].tool_calls[1]["function"].arguments)
  eq("pruned", messages[5].tool_calls[1]["function"].arguments)
end

T["tool call filtering"]["should permanently mark outdated tool calls"] = function()
  config.get_local_config = function()
    return {
      context = {
        keep = 2,
        max_tool = 3,
        exclude = {},
      },
    }
  end

  local conv = require("sia.conversation").new_conversation({ temporary = true })
  for i = 1, 5 do
    conv:add_instruction(create_tool_call_message("call_" .. i, "test_tool"))
    conv:add_instruction(create_tool_response_message("call_" .. i, "test_tool"))
  end

  local query1 = conv:prepare_messages()
  eq(2, count_pruned(query1))

  conv:add_instruction(create_tool_call_message("call_6", "test_tool"))
  conv:add_instruction(create_tool_response_message("call_6", "test_tool"))

  local query2 = conv:prepare_messages()
  eq(4, count_pruned(query2))
end

T["tool call filtering"]["should respect excluded tools"] = function()
  config.get_local_config = function()
    return {
      context = {
        keep = 2,
        max_tool = 3,
        exclude = { "important_tool" },
      },
    }
  end

  local conv = require("sia.conversation").new_conversation({ temporary = true })

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
  config.get_local_config = function()
    return {
      context = {
        keep = 2,
        max_tool = 3,
        exclude = {},
      },
    }
  end

  local conv = require("sia.conversation").new_conversation({ temporary = true })

  conv:add_instruction(create_tool_call_message("call_1", "test_tool"))
  conv:add_instruction(create_tool_response_message("call_1", "test_tool"))
  conv:add_instruction(create_tool_call_message("call_2", "test_tool"))
  conv:add_instruction(create_tool_response_message("call_2", "test_tool"))

  local failed_msg = create_tool_call_message("call_3", "test_tool")
  failed_msg.ephemeral = true
  conv:add_instruction(failed_msg)

  conv:add_instruction(create_tool_call_message("call_4", "test_tool"))
  conv:add_instruction(create_tool_response_message("call_4", "test_tool"))
  conv:add_instruction(create_tool_call_message("call_5", "test_tool"))
  conv:add_instruction(create_tool_response_message("call_5", "test_tool"))

  local query = conv:prepare_messages()

  eq(2, count_pruned(query))
end

T["tool call filtering"]["add and remove"] = function()
  config.get_local_config = function()
    return {
      context = {
        keep = 2,
        max_tool = 4,
        exclude = {},
      },
    }
  end

  local conv = require("sia.conversation").new_conversation({ temporary = true })

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
  config.get_local_config = function()
    return {
      context = {
        keep = 3,
        max_tool = 10,
        exclude = {},
      },
    }
  end

  local conv = require("sia.conversation").new_conversation({ temporary = true })

  for i = 1, 5 do
    conv:add_instruction(create_tool_call_message("call_" .. i, "test_tool"))
    conv:add_instruction(create_tool_response_message("call_" .. i, "test_tool"))
  end

  local query = conv:prepare_messages()

  eq(0, count_pruned(query))
end

T["empty assistant messages"] = MiniTest.new_set()

T["empty assistant messages"]["should filter assistant with nil content and no tool_calls"] = function()
  local conv = require("sia.conversation").new_conversation({ temporary = true })

  -- Simulate what happens during a tool-call-only response:
  -- The user asks something
  conv:add_instruction({ role = "user", content = "Do something" })

  -- The LLM responds with only tool calls. The finalize() method adds an
  -- assistant message with content=nil. With no reasoning metadata,
  -- empty_content will be false, so it should be filtered out.
  conv:add_instruction({ role = "assistant", content = nil }, nil, {
    meta = { empty_content = false },
  })

  -- Then the tool execution adds the actual tool call + result pair
  conv:add_instruction({
    {
      role = "assistant",
      tool_calls = {
        {
          id = "call_1",
          type = "function",
          ["function"] = { name = "test", arguments = "{}" },
        },
      },
    },
    {
      role = "tool",
      content = "result",
      _tool_call = {
        id = "call_1",
        ["function"] = { name = "test", arguments = "{}" },
      },
    },
  })

  local messages = conv:prepare_messages()

  -- The empty assistant message should NOT appear in prepared messages.
  -- We should only have: user, assistant (with tool_calls), tool
  for _, msg in ipairs(messages) do
    if msg.role == "assistant" then
      -- Every assistant message should have either content or tool_calls
      local has_content = msg.content ~= nil
      local has_tool_calls = msg.tool_calls ~= nil and #msg.tool_calls > 0
      eq(
        true,
        has_content or has_tool_calls,
        "assistant message has neither content nor tool_calls"
      )
    end
  end
  eq(3, #messages)
end

T["empty assistant messages"]["should keep assistant with reasoning metadata"] = function()
  local conv = require("sia.conversation").new_conversation({ temporary = true })

  conv:add_instruction({ role = "user", content = "Think about this" })

  -- A reasoning model might produce no text content but has reasoning metadata.
  -- The reasoning_opaque or reasoning is stored in meta.
  conv:add_instruction({ role = "assistant", content = nil }, nil, {
    meta = { empty_content = true, reasoning_opaque = "encrypted_reasoning_data" },
  })

  local messages = conv:prepare_messages()

  -- This message should be kept because it has meaningful metadata (reasoning)
  eq(2, #messages)
  eq("assistant", messages[2].role)
  eq("encrypted_reasoning_data", messages[2].meta.reasoning_opaque)
end

T["empty assistant messages"]["should keep assistant with reasoning"] = function()
  local conv = require("sia.conversation").new_conversation({ temporary = true })

  conv:add_instruction({ role = "user", content = "Think about this" })

  -- Responses API: reasoning with encrypted content
  conv:add_instruction({ role = "assistant", content = nil }, nil, {
    meta = {
      empty_content = true,
      reasoning = {
        summary = "I thought about it",
        encrypted_content = { id = "r_123", encrypted_content = "enc..." },
      },
    },
  })

  local messages = conv:prepare_messages()

  eq(2, #messages)
  eq("assistant", messages[2].role)
end

T["tracked instances"] = MiniTest.new_set()

T["tracked instances"]["agent instances expose preview and cancel methods"] = function()
  local conv = require("sia.conversation").new_conversation({ temporary = true })
  local agent = conv:new_agent("code/review", "Inspect the repository")
  agent.progress = "Analyzing..."

  local preview = agent:get_preview()
  eq("Agent ID: 1", preview[1])
  eq("Agent: code/review", preview[2])
  eq("Status: running", preview[3])
  eq("Task: Inspect the repository", preview[4])
  eq("Progress: Analyzing...", preview[5])

  agent:cancel()
  eq(true, agent.cancellable.is_cancelled)
  eq("Cancellation requested", agent.progress)
end

T["tracked instances"]["bash process instances expose preview and stop methods"] = function()
  local conv = require("sia.conversation").new_conversation({ temporary = true })
  local proc = conv:new_bash_process("make test", "Run tests")
  local killed = false

  proc.detached_handle = {
    process = {},
    get_output = function()
      return {
        stdout = table.concat({ "alpha", "beta", "" }, "\n"),
        stderr = table.concat({ "warn", "" }, "\n"),
      }
    end,
    is_done = function()
      return false
    end,
    kill = function()
      killed = true
    end,
  }

  local preview = proc:get_preview({ tail_lines = 1 })
  eq("Process ID: 1", preview[1])
  eq("Command: make test", preview[2])
  eq("Status: running", preview[3])
  eq(true, vim.tbl_contains(preview, "Recent stdout (last 1 lines):"))
  eq(true, vim.tbl_contains(preview, "beta"))
  eq(true, vim.tbl_contains(preview, "Recent stderr (last 1 lines):"))
  eq(true, vim.tbl_contains(preview, "warn"))

  local content, err = proc:stop()
  eq(nil, err)
  eq(true, killed)
  eq("failed", proc.status)
  eq(143, proc.code)
  eq(true, proc.interrupted)
  eq(true, proc.completed_at >= proc.started_at)
  eq(1, vim.fn.filereadable(proc.stdout_file))
  eq(1, vim.fn.filereadable(proc.stderr_file))
  eq("Process 1 terminated.", content[1])
  eq("Command: make test", content[2])

  local completed_preview = proc:get_preview({ tail_lines = 1 })
  eq("Process ID: 1", completed_preview[1])
  eq("Command: make test", completed_preview[2])
  eq("Status: failed", completed_preview[3])
  eq("Exit code: 143", completed_preview[4])
  eq("Interrupted: yes", completed_preview[5])
  eq(true, vim.tbl_contains(completed_preview, "beta"))
  eq(true, vim.tbl_contains(completed_preview, "Recent stdout (last 1 lines):"))
  eq(true, vim.tbl_contains(completed_preview, "Recent stderr (last 1 lines):"))
  eq(true, vim.tbl_contains(completed_preview, "warn"))
end

return T
