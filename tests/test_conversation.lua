local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local function create_tool_call(id, name)
  return {
    id = id,
    call_id = id,
    type = "function",
    name = name,
    arguments = '{"test": "hello"}',
  }
end

T["conversation basics"] = MiniTest.new_set()

T["conversation basics"]["add_system_message adds system entry"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_system_message("You are helpful")
  eq(1, #conv.entries)
  eq("system", conv.entries[1].role)
  eq("You are helpful", conv.entries[1].content)
end

T["conversation basics"]["add_user_message adds user entry"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_user_message("Hello world")
  eq(1, #conv.entries)
  eq("user", conv.entries[1].role)
  eq("Hello world", conv.entries[1].content)
end

T["conversation basics"]["add_assistant_message adds assistant entry"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_user_message("Hello")
  local turn_id = conv:new_turn()
  conv:add_assistant_message(turn_id, "Hi there!")
  eq(2, #conv.entries)
  eq("assistant", conv.entries[2].role)
  eq("Hi there!", conv.entries[2].content)
end

T["conversation basics"]["add_tool_message adds tool entry"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_user_message("Read file")
  local turn_id = conv:new_turn()
  local tool_call = create_tool_call("call_1", "view")

  conv:add_tool_message(turn_id, tool_call, "file content", {
    summary = "Viewed file",
  })

  eq(2, #conv.entries)
  eq("tool", conv.entries[2].role)
  eq("file content", conv.entries[2].content)
  eq("Viewed file", conv.entries[2].summary)
  eq(tool_call, conv.entries[2].tool_call)
end

T["serialization"] = MiniTest.new_set()

T["serialization"]["serialize produces correct messages"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_system_message("System prompt")
  conv:add_user_message("Hello")
  local turn_id = conv:new_turn()
  conv:add_assistant_message(turn_id, "Hi!")

  local messages = conv:serialize()
  eq(3, #messages)
  eq("system", messages[1].role)
  eq("System prompt", messages[1].content)
  eq("user", messages[2].role)
  eq("Hello", messages[2].content)
  eq("assistant", messages[3].role)
  eq("Hi!", messages[3].content)
end

T["serialization"]["serialize splits tool entries into assistant+tool messages"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_user_message("Read file")
  local turn_id = conv:new_turn()
  local tool_call = create_tool_call("call_1", "view")

  conv:add_tool_message(turn_id, tool_call, "file content", {
    summary = "Viewed file",
  })

  local messages = conv:serialize()
  -- user + assistant (with tool_call) + tool
  eq(3, #messages)
  eq("user", messages[1].role)
  eq("assistant", messages[2].role)
  eq(tool_call, messages[2].tool_call)
  eq("tool", messages[3].role)
  eq("file content", messages[3].content)
  eq(tool_call, messages[3].tool_call)
end

T["serialization"]["serialize drops ephemeral entries after first serialization"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_user_message("Hello")
  local turn_id = conv:new_turn()
  local tool_call = create_tool_call("call_1", "view")
  conv:add_tool_message(turn_id, tool_call, "ephemeral result", {
    ephemeral = true,
  })

  local messages1 = conv:serialize()
  -- First serialization includes it
  eq(3, #messages1)

  local messages2 = conv:serialize()
  -- Second serialization drops it (marked dropped)
  eq(1, #messages2)
end

T["serialization"]["serialize omits dropped entries"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_system_message("System")
  conv:add_user_message("Hello")
  local turn_id = conv:new_turn()
  conv:add_assistant_message(turn_id, "Hi!")
  conv:add_user_message("Followup")

  -- Drop after the first user message
  conv:drop_after(conv.entries[2].id)

  local messages = conv:serialize()
  eq(2, #messages)
  eq("system", messages[1].role)
  eq("user", messages[2].role)
  eq("Hello", messages[2].content)
end

T["tracked instances"] = MiniTest.new_set()

T["tracked instances"]["agent instances expose preview and cancel methods"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
  local agent = conv:new_agent("code/review", "Inspect the repository")
  agent.progress = "Analyzing..."

  local preview = agent:get_preview()
  eq(true, string.find(preview, "Agent ID: 1") ~= nil)
  eq(true, string.find(preview, "Agent: code/review") ~= nil)
  eq(true, string.find(preview, "Status: running") ~= nil)
  eq(true, string.find(preview, "Task: Inspect the repository") ~= nil)
  eq(true, string.find(preview, "Progress: Analyzing...") ~= nil)

  agent:cancel()
  eq(true, agent.cancellable.is_cancelled)
  eq("Cancellation requested", agent.progress)
end

T["tracked instances"]["bash process instances expose preview and stop methods"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
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
  eq(true, string.find(preview, "Process ID: 1") ~= nil)
  eq(true, string.find(preview, "Command: make test") ~= nil)
  eq(true, string.find(preview, "Status: running") ~= nil)
  eq(true, string.find(preview, "beta") ~= nil)
  eq(true, string.find(preview, "warn") ~= nil)

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
  eq(true, string.find(completed_preview, "Process ID: 1") ~= nil)
  eq(true, string.find(completed_preview, "Status: failed") ~= nil)
  eq(true, string.find(completed_preview, "Exit code: 143") ~= nil)
  eq(true, string.find(completed_preview, "Interrupted: yes") ~= nil)
  eq(true, string.find(completed_preview, "beta") ~= nil)
  eq(true, string.find(completed_preview, "warn") ~= nil)
end

T["turn management"] = MiniTest.new_set()

T["turn management"]["new_turn returns a turn_id"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_user_message("Hello")
  local turn_id = conv:new_turn()
  eq("string", type(turn_id))
  eq(turn_id, conv.entries[1].turn_id)
end

T["turn management"]["last_turn_id returns latest"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_user_message("Hello")
  local turn_id = conv:new_turn()
  eq(turn_id, conv:last_turn_id())
end

T["turn management"]["rollback_to drops messages at and after turn"] = function()
  local conv = require("sia.conversation").new_conversation({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })

  conv:add_system_message("System")
  conv:add_user_message("Hello")
  local turn1 = conv:new_turn()
  conv:add_assistant_message(turn1, "Hi!")
  conv:add_user_message("Followup")
  local turn2 = conv:new_turn()

  local dropped = conv:rollback_to(turn2)
  eq(true, #dropped > 0)

  -- Messages at turn2 should be dropped
  local messages = conv:serialize()
  -- System + user (Hello) + assistant (Hi!)
  eq(3, #messages)
end

return T
