local MiniTest = require("mini.test")
local T = MiniTest.new_set()
local expect = MiniTest.expect

T["context_manager"] = MiniTest.new_set()

--- Helper to create a mock system entry.
--- @param content string
--- @return sia.SystemEntry
local function make_system(content)
  return { role = "system", content = content, id = tostring(math.random(1e9)) }
end

--- Helper to create a mock user entry.
--- @param content string
--- @return sia.UserEntry
local function make_user(content)
  return { role = "user", content = content, id = tostring(math.random(1e9)) }
end

--- Helper to create a mock assistant entry.
--- @param content string
--- @param reasoning table?
--- @return sia.AssistantEntry
local function make_assistant(content, reasoning)
  return {
    role = "assistant",
    content = content,
    reasoning = reasoning,
    id = tostring(math.random(1e9)),
  }
end

--- Helper to create a mock tool entry (self-contained: tool call + result in one entry).
--- @param name string tool name
--- @param args_size integer byte size of arguments
--- @param result_size integer byte size of tool result content
--- @param opts table? optional fields like { dropped = true }
--- @return sia.ToolEntry tool_entry
local function make_tool(name, args_size, result_size, opts)
  opts = opts or {}
  return {
    role = "tool",
    id = tostring(math.random(1e9)),
    content = string.rep("r", result_size),
    dropped = opts.dropped or nil,
    tool_call = {
      id = "tc_" .. name .. "_" .. tostring(math.random(1e6)),
      name = name,
      type = "function",
      arguments = string.rep("x", args_size),
    },
  }
end

--- Helper to create a user entry with image content.
--- @param label string
--- @param data_size integer
--- @return sia.UserEntry
local function make_image_user(label, data_size)
  return {
    role = "user",
    id = tostring(math.random(1e9)),
    content = {
      {
        type = "text",
        text = label,
      },
      {
        type = "image",
        image = {
          url = "data:image/png;base64," .. string.rep("i", data_size),
        },
      },
    },
  }
end

--- Helper to create a mock conversation with entries.
--- @param context_window integer
--- @param entries table[]
--- @return table conversation mock
local function make_conversation(context_window, entries)
  return {
    model = {
      context_window = context_window,
    },
    tool_definitions = {},
    entries = entries,
    add_system_message = function(self, content)
      table.insert(self.entries, make_system(content))
    end,
    add_assistant_message = function(self, _, content)
      table.insert(self.entries, make_assistant(content))
    end,
    add_user_message = function(self, content, _, opts)
      local entry = make_user(content)
      opts = opts or {}
      entry.hide = opts.hide or false
      table.insert(self.entries, entry)
    end,
  }
end

T["context_manager"]["estimate_tokens returns reasonable estimates"] = function()
  local cm = require("sia.context_manager")

  local conversation = make_conversation(128000, {
    make_system(string.rep("a", 400)),
    make_user(string.rep("b", 800)),
  })

  local tokens = cm.estimate_tokens(conversation)
  -- 1200 bytes of content + 2*40 role overhead = 1280 bytes / 4 = 320 tokens
  expect.equality(tokens, math.floor(1280 / 4))
end

T["context_manager"]["estimate_tokens excludes image and document payloads"] = function()
  local cm = require("sia.context_manager")

  local conversation = make_conversation(128000, {
    {
      role = "user",
      id = "media",
      content = {
        { type = "text", text = "media" },
        {
          type = "image",
          image = { url = "data:image/png;base64," .. string.rep("i", 100) },
        },
        {
          type = "file",
          file = {
            filename = "doc.pdf",
            file_data = "data:application/pdf;base64," .. string.rep("d", 200),
          },
        },
      },
    },
  })

  local tokens = cm.estimate_tokens(conversation)
  local bytes = 40 + #"media"
  expect.equality(tokens, math.floor(bytes / 4))
end

T["context_manager"]["prune_oldest_media replaces oldest media and keeps latest"] = function()
  local cm = require("sia.context_manager")

  local first = make_image_user("first", 1000)
  local second = make_image_user("second", 1000)
  local conversation = make_conversation(128000, {
    make_system("system"),
    first,
    second,
  })

  local pruned = cm.prune_oldest_media(conversation, 1100, 1)

  expect.equality(pruned, 1)
  expect.equality(first.content[2].type, "text")
  expect.equality(first.content[2].text:find("Pruned older image content") ~= nil, true)
  expect.equality(second.content[2].type, "image")
end

T["context_manager"]["ensure_token_budget prunes media before threshold check"] = function()
  local cm = require("sia.context_manager")
  local config = require("sia.config")
  local old_context = vim.deepcopy(config._raw_options.settings.context)

  config.options.settings.context = vim.tbl_deep_extend("force", {}, old_context, {
    tokens = {
      media = {
        max_bytes = 1100,
        keep_last = 1,
      },
      prune = {
        at_fraction = 1,
        to_fraction = 0.70,
      },
    },
  })

  local first = make_image_user("first", 1000)
  local second = make_image_user("second", 1000)
  local conversation = make_conversation(100000, {
    make_system("system"),
    first,
    second,
  })

  local completed = false
  cm.ensure_token_budget(conversation, {
    on_complete = function(pruned, compacted)
      completed = true
      expect.equality(pruned, true)
      expect.equality(compacted, false)
    end,
  })

  expect.equality(completed, true)
  expect.equality(first.content[2].type, "text")
  expect.equality(second.content[2].type, "image")

  config.options.settings.context = old_context
end

T["context_manager"]["get_budget returns nil when no context_window"] = function()
  local cm = require("sia.context_manager")
  local conversation = {
    model = {},
    tool_definitions = {},
    entries = {},
  }

  local budget = cm.get_token_estimate(conversation)
  expect.equality(budget, nil)
end

T["context_manager"]["get_budget returns correct structure"] = function()
  local cm = require("sia.context_manager")

  local conversation = make_conversation(100000, {
    make_system(string.rep("x", 4000)),
  })

  local budget = cm.get_token_estimate(conversation)
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
    make_system(string.rep("x", 400)),
  })

  local called = false
  cm.ensure_token_budget(conversation, {
    on_complete = function(pruned, compacted)
      called = true
      expect.equality(pruned, false)
      expect.equality(compacted, false)
    end,
  })

  expect.equality(called, true)
end

T["context_manager"]["drop_oldest_tool_calls marks entries as dropped"] = function()
  local cm = require("sia.context_manager")

  local t1 = make_tool("view", 100, 2000)
  local t2 = make_tool("edit", 100, 2000)

  local conversation = make_conversation(1000, {
    make_system(string.rep("s", 100)),
    t1,
    t2,
    make_user("question"),
  })

  -- Verify initial estimate includes all entries
  local before = cm.estimate_tokens(conversation)
  expect.equality(before > 0, true)

  -- Drop with a very low target so everything droppable gets dropped
  local dropped = cm.drop_oldest_tool_calls(conversation, 0)
  expect.equality(dropped, true)
  expect.equality(t1.dropped, true)
  expect.equality(t2.dropped, true)

  -- After dropping, estimate should be lower
  local after = cm.estimate_tokens(conversation)
  expect.equality(after < before, true)
end

T["context_manager"]["drop_oldest_tool_calls drops oldest first and stops at target"] = function()
  local cm = require("sia.context_manager")

  local t1 = make_tool("view", 100, 2000)
  local t2 = make_tool("edit", 100, 2000)

  local conversation = make_conversation(10000, {
    make_system(string.rep("s", 100)),
    t1,
    t2,
    make_user("question"),
  })

  -- Set target so dropping the first entry is enough
  local full_estimate = cm.estimate_tokens(conversation)
  -- Target: drop ~one entry worth of tokens
  local target = full_estimate - 400

  local dropped = cm.drop_oldest_tool_calls(conversation, target)
  expect.equality(dropped, true)

  -- Oldest entry should be dropped
  expect.equality(t1.dropped, true)

  -- Second entry should still be active (not dropped)
  expect.no_equality(t2.dropped, true)
end

T["context_manager"]["already-dropped entries are not re-processed"] = function()
  local cm = require("sia.context_manager")

  local t1 = make_tool("view", 100, 2000, { dropped = true })
  local t2 = make_tool("edit", 100, 2000)

  local conversation = make_conversation(10000, {
    make_system(string.rep("s", 100)),
    t1,
    t2,
    make_user("question"),
  })

  -- Only the second entry should be droppable, first is already dropped
  local dropped = cm.drop_oldest_tool_calls(conversation, 0)
  expect.equality(dropped, true)
  expect.equality(t2.dropped, true)
end

T["context_manager"]["estimate_tokens decreases after dropping"] = function()
  local cm = require("sia.context_manager")

  local t1 = make_tool("view", 100, 4000)

  local conversation = make_conversation(10000, {
    make_system(string.rep("s", 200)),
    t1,
    make_user(string.rep("q", 200)),
  })

  local before = cm.estimate_tokens(conversation)

  cm.drop_oldest_tool_calls(conversation, 0)

  local after = cm.estimate_tokens(conversation)

  -- The tool entry was ~4100 + 40 overhead bytes = ~1035 tokens
  -- After dropping, those should be gone from the estimate
  expect.equality(after < before, true)
  expect.equality(before - after > 1000, true)
end

T["context_manager"]["prune_if_needed drops tool calls when over threshold"] = function()
  local cm = require("sia.context_manager")

  -- Small context window: 2000 tokens
  -- Fill it to >85%: need ~1700+ tokens = ~6800+ bytes
  -- Each tool entry: 3200 content + 100 args + ~4 name + 40 overhead ≈ 3344 bytes
  -- Two tools: ~6688, system: 240, user: 240, total ~7168 / 4 ≈ 1792 tokens > 1700
  local t1 = make_tool("view", 100, 3200)
  local t2 = make_tool("edit", 100, 3200)

  local conversation = make_conversation(2000, {
    make_system(string.rep("s", 200)),
    t1,
    t2,
    make_user(string.rep("q", 200)),
  })

  local budget = cm.get_token_estimate(conversation)
  -- Verify we're actually over threshold
  expect.equality(budget.percent >= 0.85, true)

  local called = false
  cm.ensure_token_budget(conversation, {
    on_complete = function(pruned, compacted)
      called = true
      expect.equality(pruned, true)
      expect.equality(compacted, false)
    end,
  })

  expect.equality(called, true)

  -- At least one entry should be dropped
  local any_dropped = t1.dropped == true or t2.dropped == true
  expect.equality(any_dropped, true)

  -- After pruning, we should be under target (70% of 2000 = 1400)
  local after = cm.estimate_tokens(conversation)
  expect.equality(after <= 1400, true)
end

--- Helper to mock sia.assistant.fetch_response and sia.conversation.new_conversation
--- for testing compact_conversation end-to-end.
--- @param summary_response string the summary text the mock summarizer returns
--- @return { captured_entries: table[] } tracker to inspect what was sent to summarizer
local function mock_compaction(summary_response)
  local tracker = { captured_entries = {} }

  -- Mock new_conversation to return a lightweight object that captures entries
  local real_conv = require("sia.conversation")
  tracker._real_new = real_conv.new
  real_conv.new = function(_, _)
    return {
      add_system_message = function(_, content)
        table.insert(tracker.captured_entries, {
          role = "system",
          content = content,
        })
      end,
      add_assistant_message = function(_, _, content)
        table.insert(tracker.captured_entries, {
          role = "assistant",
          content = content,
        })
      end,
      add_user_message = function(_, content)
        table.insert(tracker.captured_entries, {
          role = "user",
          content = content,
        })
      end,
    }
  end

  -- Mock fetch_response to synchronously call back with the summary
  local assistant = require("sia.assistant")
  tracker._real_fetch = assistant.fetch_response
  assistant.fetch_response = function(_, callback)
    callback(summary_response)
  end

  -- Force compaction by making the token budget extremely small.
  local config = require("sia.config")
  tracker._old_context = vim.deepcopy(config._raw_options.settings.context)
  config.options.settings.context = vim.tbl_deep_extend(
    "force",
    {},
    tracker._old_context,
    {
      tokens = {
        prune = {
          at_fraction = 0.01,
          to_fraction = 0.001,
        },
        compact = {
          oldest_fraction = 0.5,
        },
      },
    }
  )

  tracker.restore = function()
    real_conv.new = tracker._real_new
    assistant.fetch_response = tracker._real_fetch
    config.options.settings.context = tracker._old_context
  end

  return tracker
end

T["context_manager"]["compact includes dropped entries in summarizer input"] = function()
  local cm = require("sia.context_manager")

  local t1 = make_tool("view", 50, 200, { dropped = true })
  local tracker = mock_compaction("Summary of conversation")

  local conversation = make_conversation(50, {
    make_system("system prompt"),
    t1,
    make_user("hello"),
    make_assistant("hi there"),
  })

  local completed = false
  cm.ensure_token_budget(conversation, {
    on_complete = function(pruned, compacted)
      completed = true
      expect.equality(pruned, true)
      expect.equality(compacted, true)
    end,
  })

  expect.equality(completed, true)

  -- The dropped tool entry should have been sent to the summarizer
  local found_tool_result = false
  local found_tool_call = false
  for _, entry in ipairs(tracker.captured_entries) do
    if entry.content and entry.content:find("%[Tool result: view%]") then
      found_tool_result = true
    end
    if entry.content and entry.content:find("%[Tool call: view") then
      found_tool_call = true
    end
  end

  expect.equality(found_tool_call, true)
  expect.equality(found_tool_result, true)

  tracker.restore()
end

T["context_manager"]["compact removes dropped entries after successful compaction"] = function()
  local cm = require("sia.context_manager")

  local t1 = make_tool("view", 50, 200, { dropped = true })
  local tracker = mock_compaction("Summary of conversation")

  local conversation = make_conversation(50, {
    make_system("system prompt"),
    t1,
    make_user("hello"),
    make_assistant("hi there"),
  })

  cm.ensure_token_budget(conversation, {
    on_complete = function() end,
  })

  -- The originally-dropped tool entry should be completely removed
  local found_t1 = false
  for _, entry in ipairs(conversation.entries) do
    if entry == t1 then
      found_t1 = true
    end
  end
  expect.equality(found_t1, false)

  tracker.restore()
end

T["context_manager"]["compact normalizes tool entries to plain text"] = function()
  local cm = require("sia.context_manager")

  local tracker = mock_compaction("Summary")

  -- Create a conversation with an active (non-dropped) tool entry that will be compacted
  local conversation = make_conversation(50, {
    make_system("system prompt"),
    make_user("read the file"),
    make_tool("view", 0, 0),
    make_assistant("I read the file"),
  })

  -- Manually set the tool entry args/content for verification
  conversation.entries[3].tool_call.arguments = '{"path":"foo.lua"}'
  conversation.entries[3].content = "file contents here"

  cm.ensure_token_budget(conversation, {
    on_complete = function() end,
  })

  -- All entries sent to summarizer should be plain user/assistant messages
  -- with no tool_call fields — just normalized text
  for _, entry in ipairs(tracker.captured_entries) do
    expect.equality(entry.tool_call, nil)
    expect.equality(type(entry.role), "string")
    expect.equality(type(entry.content), "string")
    -- Tool role should be converted to user
    expect.no_equality(entry.role, "tool")
  end

  -- Should contain the normalized tool call text
  local found_view_call = false
  local found_view_result = false
  for _, entry in ipairs(tracker.captured_entries) do
    if entry.content:find("%[Tool call: view") then
      found_view_call = true
    end
    if entry.content:find("%[Tool result: view%]") then
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
    make_system("system prompt"),
    make_user("hello"),
    make_assistant("hi there"),
  })

  cm.ensure_token_budget(conversation, {
    on_complete = function(pruned, compacted)
      expect.equality(pruned, true)
      expect.equality(compacted, true)
    end,
  })

  -- Should have the system message + the summary message
  local found_summary = false
  for _, entry in ipairs(conversation.entries) do
    if
      entry.content
      and type(entry.content) == "string"
      and entry.content:find("This is the summary content")
    then
      found_summary = true
      expect.equality(entry.role, "user")
    end
  end
  expect.equality(found_summary, true)

  tracker.restore()
end

T["context_manager"]["compact does not include dropped entries in compact_ratio count"] = function()
  local cm = require("sia.context_manager")

  -- 2 dropped tool entries + 4 active non-system entries
  local t1 = make_tool("view", 50, 200, { dropped = true })
  local t2 = make_tool("edit", 50, 200, { dropped = true })
  local tracker = mock_compaction("Summary")

  local conversation = make_conversation(50, {
    make_system("system prompt"),
    t1,
    t2,
    make_user("question 1"),
    make_assistant("answer 1"),
    make_user("question 2"),
    make_assistant("answer 2"),
  })

  -- mock_compaction sets compact.oldest_fraction = 0.5
  -- With 4 active non-system entries, should compact 2 active + all 2 dropped = 4
  -- Plus the system prompt = 5 total in captured_entries

  cm.ensure_token_budget(conversation, {
    on_complete = function() end,
  })

  -- 2 dropped entries + 2 of the 4 active non-system + system prompt = 5 entries
  expect.equality(#tracker.captured_entries, 5)

  tracker.restore()
end

T["context_manager"]["compact removes both dropped and compacted entries"] = function()
  local cm = require("sia.context_manager")

  local t1 = make_tool("view", 50, 200, { dropped = true })
  local tracker = mock_compaction("Summary pass 1")

  local u1 = make_user("question 1")
  local a1 = make_assistant("answer 1")

  local conversation = make_conversation(50, {
    make_system("system prompt"),
    t1,
    u1,
    a1,
    make_user("question 2"),
    make_assistant("answer 2"),
  })

  cm.ensure_token_budget(conversation, {
    on_complete = function() end,
  })

  -- After compaction: the dropped entry (t1) and the compacted active entries
  -- (u1, a1) should all be removed from conversation.entries
  for _, entry in ipairs(conversation.entries) do
    expect.no_equality(entry, t1)
    expect.no_equality(entry, u1)
    expect.no_equality(entry, a1)
  end

  tracker.restore()
end

T["context_manager"]["repeated compaction does not re-summarize already compacted history"] = function()
  local cm = require("sia.context_manager")

  -- First pass
  local tracker1 = mock_compaction("Summary of pass 1")

  local conversation = make_conversation(50, {
    make_system("system prompt"),
    make_user("question 1"),
    make_assistant("answer 1"),
    make_user("question 2"),
    make_assistant("answer 2"),
  })

  cm.ensure_token_budget(conversation, {
    on_complete = function() end,
  })

  -- After first pass, some entries should be replaced by the summary
  local entries_after_pass1 = #conversation.entries
  tracker1.restore()

  -- Add more entries to trigger compaction again
  table.insert(conversation.entries, make_user("question 3"))
  table.insert(conversation.entries, make_assistant("answer 3"))

  -- Second pass
  local tracker2 = mock_compaction("Summary of pass 2")

  cm.ensure_token_budget(conversation, {
    on_complete = function() end,
  })

  -- The second pass should NOT contain "question 1" or "answer 1" in the
  -- summarizer input, since those were already removed in pass 1
  for _, entry in ipairs(tracker2.captured_entries) do
    if entry.content then
      expect.equality(entry.content:find("question 1"), nil)
      expect.equality(entry.content:find("answer 1"), nil)
    end
  end

  tracker2.restore()
end

T["context_manager"]["normalize handles reasoning-only assistant entries"] = function()
  local cm = require("sia.context_manager")

  local tracker = mock_compaction("Summary")

  local conversation = make_conversation(50, {
    make_system("system prompt"),
    make_user("think about this"),
    make_assistant(nil, { text = "deep thought about the problem" }),
    make_user("what did you think?"),
    make_assistant("I thought carefully"),
  })

  cm.ensure_token_budget(conversation, {
    on_complete = function() end,
  })

  -- The reasoning-only assistant entry should appear in the summarizer input
  local found_reasoning = false
  for _, entry in ipairs(tracker.captured_entries) do
    if entry.content and entry.content:find("deep thought about the problem") then
      found_reasoning = true
    end
  end
  expect.equality(found_reasoning, true)

  tracker.restore()
end

return T
