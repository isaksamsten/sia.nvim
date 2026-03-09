local MiniTest = require("mini.test")
local T = MiniTest.new_set()
local expect = MiniTest.expect

T["context_manager"] = MiniTest.new_set()

--- Helper to create a mock message with has_content().
--- @param tbl table raw message fields
--- @return table message with has_content method
local function make_message(tbl)
  tbl.has_content = function(self)
    return self.content ~= nil or self.tool_calls ~= nil
  end
  return tbl
end

--- Helper to create a mock conversation with a small context window.
--- The mock's prepare_messages filters out "dropped", "superseded", and "failed"
--- messages, matching real Conversation behavior.
--- @param context_window integer
--- @param messages table[]
--- @return table conversation mock
local function make_conversation(context_window, messages)
  return {
    model = {
      get_param = function(_, key)
        if key == "context_window" then
          return context_window
        end
        return nil
      end,
    },
    tools = {},
    messages = messages,
    _invalidate_cache = function() end,
    set_message_status = function(_, message, status)
      message.status = status
    end,
    prepare_messages = function(self)
      local result = {}
      for _, m in ipairs(self.messages) do
        if
          m.status ~= "dropped"
          and m.status ~= "superseded"
          and m.status ~= "failed"
        then
          table.insert(result, m)
        end
      end
      return result
    end,
    add_instruction = function(self, instruction)
      table.insert(self.messages, make_message(instruction))
    end,
    clear_user_instructions = function(self)
      self.messages = vim
        .iter(self.messages)
        :filter(function(m)
          return m.role == "system"
        end)
        :totable()
    end,
  }
end

--- Helper to make a tool call pair: an assistant message with tool_calls
--- and a matching tool result message.
--- @param id string tool call id
--- @param name string tool name
--- @param args_size integer byte size of arguments
--- @param result_size integer byte size of tool result content
--- @param status string? optional status for both messages
--- @return table assistant_msg, table tool_msg
local function make_tool_pair(id, name, args_size, result_size, status)
  local assistant_msg = make_message({
    role = "assistant",
    content = "",
    status = status,
    tool_calls = {
      {
        id = id,
        ["function"] = {
          name = name,
          arguments = string.rep("x", args_size),
        },
      },
    },
  })
  local tool_msg = make_message({
    role = "tool",
    content = string.rep("r", result_size),
    status = status,
    _tool_call = {
      id = id,
      ["function"] = {
        name = name,
        arguments = string.rep("x", args_size),
      },
    },
  })
  return assistant_msg, tool_msg
end

T["context_manager"]["estimate_tokens returns reasonable estimates"] = function()
  local cm = require("sia.context_manager")

  local conversation = make_conversation(128000, {
    { role = "system", content = string.rep("a", 400) },
    { role = "user", content = string.rep("b", 800) },
  })

  local tokens = cm.estimate_tokens(conversation)
  -- 1200 bytes of content + 2*40 role overhead = 1280 bytes / 4 = 320 tokens
  expect.equality(tokens, math.floor(1280 / 4))
end

T["context_manager"]["get_budget returns nil when no context_window"] = function()
  local cm = require("sia.context_manager")
  local conversation = {
    model = {
      get_param = function(_, key)
        return nil
      end,
    },
    tools = {},
    messages = {},
    prepare_messages = function(_)
      return {}
    end,
  }

  local budget = cm.get_budget(conversation)
  expect.equality(budget, nil)
end

T["context_manager"]["get_budget returns correct structure"] = function()
  local cm = require("sia.context_manager")

  local conversation = make_conversation(100000, {
    { role = "system", content = string.rep("x", 4000) },
  })

  local budget = cm.get_budget(conversation)
  expect.no_equality(budget, nil)
  expect.equality(type(budget.estimated), "number")
  expect.equality(budget.limit, 100000)
  expect.equality(type(budget.percent), "number")
  -- 4000 + 40 overhead = 4040 bytes / 4 = 1010 tokens
  expect.equality(budget.estimated, 1010)
end

T["context_manager"]["prune_if_needed does nothing when under threshold"] = function()
  local cm = require("sia.context_manager")

  local conversation = make_conversation(100000, {
    { role = "system", content = string.rep("x", 400) },
  })

  local called = false
  cm.prune_if_needed(conversation, {
    on_complete = function(pruned, compacted)
      called = true
      expect.equality(pruned, false)
      expect.equality(compacted, false)
    end,
  })

  expect.equality(called, true)
end

T["context_manager"]["drop_oldest_tool_calls marks pairs as dropped"] = function()
  local cm = require("sia.context_manager")

  local a1, t1 = make_tool_pair("tc1", "view", 100, 2000)
  local a2, t2 = make_tool_pair("tc2", "edit", 100, 2000)

  local conversation = make_conversation(1000, {
    { role = "system", content = string.rep("s", 100) },
    a1,
    t1,
    a2,
    t2,
    { role = "user", content = "question" },
  })

  -- Verify initial estimate includes all messages
  local before = cm.estimate_tokens(conversation)
  expect.equality(before > 0, true)

  -- Drop with a very low target so everything droppable gets dropped
  local dropped = cm.drop_oldest_tool_calls(conversation, 0)
  expect.equality(dropped, true)
  expect.equality(a1.status, "dropped")
  expect.equality(t1.status, "dropped")
  expect.equality(a2.status, "dropped")
  expect.equality(t2.status, "dropped")

  -- After dropping, estimate should be lower (dropped messages filtered out)
  local after = cm.estimate_tokens(conversation)
  expect.equality(after < before, true)
end

T["context_manager"]["drop_oldest_tool_calls drops oldest first and stops at target"] = function()
  local cm = require("sia.context_manager")

  local a1, t1 = make_tool_pair("tc1", "view", 100, 2000)
  local a2, t2 = make_tool_pair("tc2", "edit", 100, 2000)

  local conversation = make_conversation(10000, {
    { role = "system", content = string.rep("s", 100) },
    a1,
    t1,
    a2,
    t2,
    { role = "user", content = "question" },
  })

  -- Set target so dropping the first pair is enough
  local full_estimate = cm.estimate_tokens(conversation)
  -- Target: drop ~one pair worth of tokens
  local target = full_estimate - 400

  local dropped = cm.drop_oldest_tool_calls(conversation, target)
  expect.equality(dropped, true)

  -- Oldest pair should be dropped
  expect.equality(a1.status, "dropped")
  expect.equality(t1.status, "dropped")

  -- Second pair should still be active (not dropped)
  expect.no_equality(a2.status, "dropped")
  expect.no_equality(t2.status, "dropped")
end

T["context_manager"]["outdated tool calls are droppable"] = function()
  local cm = require("sia.context_manager")

  local a1, t1 = make_tool_pair("tc1", "view", 100, 2000, "outdated")
  local a2, t2 = make_tool_pair("tc2", "edit", 100, 2000)

  local conversation = make_conversation(10000, {
    { role = "system", content = string.rep("s", 100) },
    a1,
    t1,
    a2,
    t2,
    { role = "user", content = "question" },
  })

  -- Drop with target 0 so everything gets dropped
  local dropped = cm.drop_oldest_tool_calls(conversation, 0)
  expect.equality(dropped, true)

  -- The outdated pair should now be fully dropped (upgraded from outdated)
  expect.equality(a1.status, "dropped")
  expect.equality(t1.status, "dropped")
  -- The active pair should also be dropped
  expect.equality(a2.status, "dropped")
  expect.equality(t2.status, "dropped")
end

T["context_manager"]["outdated pairs are dropped before active ones"] = function()
  local cm = require("sia.context_manager")

  local a1, t1 = make_tool_pair("tc1", "view", 100, 2000, "outdated")
  local a2, t2 = make_tool_pair("tc2", "edit", 100, 2000)

  local conversation = make_conversation(10000, {
    { role = "system", content = string.rep("s", 100) },
    a1,
    t1,
    a2,
    t2,
    { role = "user", content = "question" },
  })

  -- Set target so dropping just the outdated pair is enough
  local full_estimate = cm.estimate_tokens(conversation)
  local target = full_estimate - 400

  local dropped = cm.drop_oldest_tool_calls(conversation, target)
  expect.equality(dropped, true)

  -- Outdated pair upgraded to dropped
  expect.equality(a1.status, "dropped")
  expect.equality(t1.status, "dropped")

  -- Active pair should NOT be dropped (we reached target)
  expect.no_equality(a2.status, "dropped")
  expect.no_equality(t2.status, "dropped")
end

T["context_manager"]["prune_if_needed drops tool calls when over threshold"] = function()
  local cm = require("sia.context_manager")

  -- Small context window: 2000 tokens
  -- Fill it to >85%: need ~1700+ tokens = ~6800+ bytes
  local a1, t1 = make_tool_pair("tc1", "view", 100, 3000)
  local a2, t2 = make_tool_pair("tc2", "edit", 100, 3000)

  local conversation = make_conversation(2000, {
    { role = "system", content = string.rep("s", 200) },
    a1,
    t1,
    a2,
    t2,
    { role = "user", content = string.rep("q", 200) },
  })

  local budget = cm.get_budget(conversation)
  -- Verify we're actually over threshold
  expect.equality(budget.percent >= 0.85, true)

  local called = false
  cm.prune_if_needed(conversation, {
    on_complete = function(pruned, compacted)
      called = true
      expect.equality(pruned, true)
      expect.equality(compacted, false)
    end,
  })

  expect.equality(called, true)

  -- At least one pair should be dropped
  local any_dropped = a1.status == "dropped" or a2.status == "dropped"
  expect.equality(any_dropped, true)

  -- After pruning, we should be under target (70% of 2000 = 1400)
  local after = cm.estimate_tokens(conversation)
  expect.equality(after <= 1400, true)
end

T["context_manager"]["already-dropped pairs are not re-processed"] = function()
  local cm = require("sia.context_manager")

  local a1, t1 = make_tool_pair("tc1", "view", 100, 2000, "dropped")
  local a2, t2 = make_tool_pair("tc2", "edit", 100, 2000)

  local conversation = make_conversation(10000, {
    { role = "system", content = string.rep("s", 100) },
    a1,
    t1,
    a2,
    t2,
    { role = "user", content = "question" },
  })

  -- Only the second pair should be droppable, first is already dropped
  local dropped = cm.drop_oldest_tool_calls(conversation, 0)
  expect.equality(dropped, true)
  expect.equality(a2.status, "dropped")
  expect.equality(t2.status, "dropped")
end

T["context_manager"]["superseded pairs are not droppable"] = function()
  local cm = require("sia.context_manager")

  local a1, t1 = make_tool_pair("tc1", "view", 100, 2000, "superseded")

  local conversation = make_conversation(10000, {
    { role = "system", content = string.rep("s", 100) },
    a1,
    t1,
    { role = "user", content = "question" },
  })

  local dropped = cm.drop_oldest_tool_calls(conversation, 0)
  -- Nothing to drop since the only pair is superseded
  expect.equality(dropped, false)
  expect.equality(a1.status, "superseded")
  expect.equality(t1.status, "superseded")
end

T["context_manager"]["estimate_tokens decreases after dropping"] = function()
  local cm = require("sia.context_manager")

  local a1, t1 = make_tool_pair("tc1", "view", 100, 4000)

  local conversation = make_conversation(10000, {
    { role = "system", content = string.rep("s", 200) },
    a1,
    t1,
    { role = "user", content = string.rep("q", 200) },
  })

  local before = cm.estimate_tokens(conversation)

  cm.drop_oldest_tool_calls(conversation, 0)

  local after = cm.estimate_tokens(conversation)

  -- The tool pair was ~4300 bytes = ~1075 tokens
  -- After dropping, those should be gone from the estimate
  expect.equality(after < before, true)
  expect.equality(before - after > 1000, true)
end

--- Helper to mock sia.assistant.fetch_response and sia.conversation.Conversation:new
--- for testing compact_conversation end-to-end.
--- @param summary_response string the summary text the mock summarizer returns
--- @return { captured_instructions: table[] } tracker to inspect what was sent to summarizer
local function mock_compaction(summary_response)
  local tracker = { captured_instructions = {} }

  -- Mock Conversation:new to return a lightweight object that captures instructions
  local real_conv = require("sia.conversation")
  tracker._real_new = real_conv.Conversation.new
  real_conv.Conversation.new = function(_, _, _)
    return {
      add_instruction = function(_, instruction)
        table.insert(tracker.captured_instructions, instruction)
      end,
      prepare_messages = function(_)
        return {}
      end,
    }
  end

  -- Mock fetch_response to synchronously call back with the summary
  local assistant = require("sia.assistant")
  tracker._real_fetch = assistant.fetch_response
  assistant.fetch_response = function(_, callback)
    callback(summary_response)
  end

  -- Ensure context_management config is set so prune_if_needed proceeds
  local config = require("sia.config")
  tracker._old_context_management = config.options.settings.context_management
  config.options.settings.context_management = {
    prune_threshold = 0.01,
    target_after_prune = 0.001,
    compact_ratio = 0.5,
  }

  tracker.restore = function()
    real_conv.Conversation.new = tracker._real_new
    assistant.fetch_response = tracker._real_fetch
    config.options.settings.context_management = tracker._old_context_management
  end

  return tracker
end

T["context_manager"]["compact includes dropped messages in summarizer input"] = function()
  local cm = require("sia.context_manager")

  local a1, t1 = make_tool_pair("tc1", "view", 50, 200, "dropped")
  local tracker = mock_compaction("Summary of conversation")

  local conversation = make_conversation(50, {
    make_message({ role = "system", content = "system prompt" }),
    a1,
    t1,
    make_message({ role = "user", content = "hello" }),
    make_message({ role = "assistant", content = "hi there" }),
  })

  local completed = false
  cm.prune_if_needed(conversation, {
    on_complete = function(pruned, compacted)
      completed = true
      expect.equality(pruned, true)
      expect.equality(compacted, true)
    end,
  })

  expect.equality(completed, true)

  -- The dropped tool call messages should have been sent to the summarizer
  local found_tool_result = false
  local found_tool_call = false
  for _, instr in ipairs(tracker.captured_instructions) do
    if instr.content and instr.content:find("%[Tool result: view%]") then
      found_tool_result = true
    end
    if instr.content and instr.content:find("%[Tool call: view") then
      found_tool_call = true
    end
  end

  expect.equality(found_tool_call, true)
  expect.equality(found_tool_result, true)

  tracker.restore()
end

T["context_manager"]["compact removes dropped messages after successful compaction"] = function()
  local cm = require("sia.context_manager")

  local a1, t1 = make_tool_pair("tc1", "view", 50, 200, "dropped")
  local tracker = mock_compaction("Summary of conversation")

  local conversation = make_conversation(50, {
    make_message({ role = "system", content = "system prompt" }),
    a1,
    t1,
    make_message({ role = "user", content = "hello" }),
    make_message({ role = "assistant", content = "hi there" }),
  })

  cm.prune_if_needed(conversation, {
    on_complete = function() end,
  })

  -- The originally-dropped tool pair should be completely removed
  for _, m in ipairs(conversation.messages) do
    if m.role == "tool" then
      -- No tool messages should remain (a1/t1 were the only tool pair)
      error("Tool message should have been removed")
    end
  end

  -- Verify a1 and t1 are no longer in the messages array (by identity)
  local found_a1, found_t1 = false, false
  for _, m in ipairs(conversation.messages) do
    if m == a1 then
      found_a1 = true
    end
    if m == t1 then
      found_t1 = true
    end
  end
  expect.equality(found_a1, false)
  expect.equality(found_t1, false)

  tracker.restore()
end

T["context_manager"]["compact removes superseded messages after successful compaction"] = function()
  local cm = require("sia.context_manager")

  local a1, t1 = make_tool_pair("tc1", "view", 50, 200, "superseded")
  local tracker = mock_compaction("Summary of conversation")

  local conversation = make_conversation(50, {
    make_message({ role = "system", content = "system prompt" }),
    a1,
    t1,
    make_message({ role = "user", content = "hello" }),
    make_message({ role = "assistant", content = "hi there" }),
  })

  cm.prune_if_needed(conversation, {
    on_complete = function() end,
  })

  -- Superseded messages should be removed
  for _, m in ipairs(conversation.messages) do
    expect.no_equality(m.status, "superseded")
  end

  tracker.restore()
end

T["context_manager"]["compact normalizes tool calls to plain text"] = function()
  local cm = require("sia.context_manager")

  local tracker = mock_compaction("Summary")

  -- Create a conversation with active (non-dropped) tool calls that will be compacted
  local conversation = make_conversation(50, {
    make_message({ role = "system", content = "system prompt" }),
    make_message({ role = "user", content = "read the file" }),
    make_message({
      role = "assistant",
      content = "",
      tool_calls = {
        {
          id = "toolu_anthropic_123",
          ["function"] = { name = "view", arguments = '{"path":"foo.lua"}' },
        },
      },
    }),
    make_message({
      role = "tool",
      content = "file contents here",
      _tool_call = {
        id = "toolu_anthropic_123",
        ["function"] = { name = "view", arguments = '{"path":"foo.lua"}' },
      },
    }),
    make_message({ role = "assistant", content = "I read the file" }),
  })

  cm.prune_if_needed(conversation, {
    on_complete = function() end,
  })

  -- All instructions sent to summarizer should be plain user/assistant messages
  -- with no tool_calls, _tool_call fields — just normalized text
  for _, instr in ipairs(tracker.captured_instructions) do
    expect.equality(instr.tool_calls, nil)
    expect.equality(instr._tool_call, nil)
    expect.equality(type(instr.role), "string")
    expect.equality(type(instr.content), "string")
    -- Tool role should be converted to user
    expect.no_equality(instr.role, "tool")
  end

  -- Should contain the normalized tool call text
  local found_view_call = false
  local found_view_result = false
  for _, instr in ipairs(tracker.captured_instructions) do
    if instr.content:find("%[Tool call: view") then
      found_view_call = true
    end
    if instr.content:find("%[Tool result: view%]") then
      found_view_result = true
    end
  end
  expect.equality(found_view_call, true)
  expect.equality(found_view_result, true)

  tracker.restore()
end

T["context_manager"]["compact adds summary message to conversation"] = function()
  local cm = require("sia.context_manager")

  local tracker = mock_compaction("This is the summary content")

  local conversation = make_conversation(50, {
    make_message({ role = "system", content = "system prompt" }),
    make_message({ role = "user", content = "hello" }),
    make_message({ role = "assistant", content = "hi there" }),
  })

  cm.prune_if_needed(conversation, {
    on_complete = function(pruned, compacted)
      expect.equality(pruned, true)
      expect.equality(compacted, true)
    end,
  })

  -- Should have the system message + the summary message
  local found_summary = false
  for _, m in ipairs(conversation.messages) do
    if
      m.content
      and type(m.content) == "string"
      and m.content:find("This is the summary content")
    then
      found_summary = true
      expect.equality(m.role, "user")
    end
  end
  expect.equality(found_summary, true)

  tracker.restore()
end

T["context_manager"]["compact does not include dropped messages in compact_ratio count"] = function()
  local cm = require("sia.context_manager")

  -- 4 dropped messages + 4 active non-system messages
  local a1, t1 = make_tool_pair("tc1", "view", 50, 200, "dropped")
  local a2, t2 = make_tool_pair("tc2", "edit", 50, 200, "dropped")
  local tracker = mock_compaction("Summary")

  local conversation = make_conversation(50, {
    make_message({ role = "system", content = "system prompt" }),
    a1,
    t1,
    a2,
    t2,
    make_message({ role = "user", content = "question 1" }),
    make_message({ role = "assistant", content = "answer 1" }),
    make_message({ role = "user", content = "question 2" }),
    make_message({ role = "assistant", content = "answer 2" }),
  })

  -- mock_compaction sets compact_ratio = 0.5
  -- With 4 active non-system messages, should compact 2 active + all 4 dropped = 6

  cm.prune_if_needed(conversation, {
    on_complete = function() end,
  })

  -- All 4 dropped messages + 2 of the 4 active non-system = 6 instructions
  expect.equality(#tracker.captured_instructions, 6)

  tracker.restore()
end

return T
