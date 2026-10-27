local eq = MiniTest.expect.equality
local persistence = require("sia.persistence")
local root, stdpath
local persistence_enabled

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      root = vim.fn.tempname()
      local settings = require("sia.config").options.settings.persistence
      persistence_enabled = settings.enable
      settings.enable = true
      stdpath = vim.fn.stdpath
      vim.fn.stdpath = function(kind)
        return kind == "data" and root or stdpath(kind)
      end
    end,
    post_case = function()
      vim.fn.stdpath = stdpath
      require("sia.config").options.settings.persistence.enable = persistence_enabled
      vim.fn.delete(root, "rf")
    end,
  },
})

local function conversation()
  return require("sia.conversation").new({
    model = require("sia.model").resolve("openai/gpt-4.1"),
  })
end

local function call()
  return {
    id = "call-1",
    type = "function",
    name = "view",
    arguments = '{"path":"file"}',
  }
end

T["read-only serialization does not consume ephemeral entries"] = function()
  local conv = conversation()
  conv:add_user_message("Hello")
  conv:add_tool_message("turn", call(), "one-shot", { ephemeral = true })
  eq(#conv:serialize({ read_only = true }), 1)
  eq(conv.entries[2].dropped == true, false)
  eq(#conv:serialize(), 3)
  eq(conv.entries[2].dropped, true)
  eq(#conv:serialize({ read_only = true }), 1)
  conv:destroy()
end

T["snapshot retains content and calls but excludes reasoning and runtime state"] = function()
  local conv = conversation()
  conv:add_system_message("System")
  conv:add_user_message("Hello")
  conv:add_assistant_message(
    "turn",
    nil,
    { text = "private", opaque = { secret = true } }
  )
  conv:add_assistant_message("turn", "Answer", { text = "private" })
  conv:add_tool_message("turn", call(), "output", {
    summary = { header = "Read file", on_activate = function() end },
  })
  conv:add_user_message("dropped")
  conv.entries[#conv.entries].dropped = true
  conv.approved_tools.view = true
  local snapshot = persistence.snapshot(conv)
  eq(#snapshot.messages, 5)
  eq(snapshot.messages[3], { role = "assistant", content = "Answer" })
  eq(snapshot.messages[4], { role = "assistant", tool_call = call() })
  eq(snapshot.messages[5], {
    role = "tool",
    tool_call = call(),
    content = "output",
    summary = { header = "Read file" },
  })
  eq(snapshot.approved_tools, nil)
  eq(snapshot.entries, nil)
  snapshot.messages[4].tool_call.name = "changed"
  eq(conv.entries[5].tool_call.name, "view")
  conv:destroy()
end

T["atomic saves replace dropped messages and restore fresh runtime"] = function()
  local conv = conversation()
  conv:add_system_message("System")
  conv:add_user_message("Hello")
  conv:add_tool_message("turn", call(), "output")
  conv:add_assistant_message("turn", "Answer")
  conv.name = "Saved title"
  conv.approved_tools.view = true
  eq(persistence.save(conv), true)
  local snapshot = assert(persistence.load(conv.uuid))
  eq(#snapshot.messages, 5)
  conv.entries[3].dropped = true
  eq(persistence.save(conv), true)
  snapshot = assert(persistence.load(conv.uuid))
  eq(#snapshot.messages, 3)
  local path = vim.fs.joinpath(root, "sia", "conversations", conv.uuid .. ".json")
  eq(vim.uv.fs_stat(path).mode % 512, 384)
  eq(#vim.fn.glob(vim.fs.dirname(path) .. "/*.tmp", false, true), 0)
  local restored = assert(persistence.restore(conv.uuid))
  eq(restored.uuid, conv.uuid)
  eq(restored.name, "Saved title")
  eq(restored.model.name, conv.model.name)
  eq(restored.approved_tools, {})
  eq(restored.entries[3].content, "Answer")
  eq(restored.entries[4].hide, true)
  eq(restored.tracker == conv.tracker, false)
  restored:destroy()
  conv:destroy()
end

T["restore rebuilds tool entries and preserves multipart content"] = function()
  local conv = conversation()
  local content = {
    { type = "text", text = "Hello" },
    { type = "image", image = { url = "data:image/png;base64,AA" } },
  }
  conv:add_user_message(content)
  conv:add_tool_message("turn", call(), "output")
  conv:add_assistant_message("turn", "Answer")
  eq(persistence.save(conv), true)
  local restored = assert(persistence.restore(conv.uuid))
  eq(restored.entries[1].content, content)
  eq(restored.entries[2].role, "tool")
  eq(restored.entries[2].tool_call, call())
  eq(restored.entries[2].content, "output")
  eq(restored.entries[2].turn_id, restored.entries[1].turn_id)
  restored:destroy()
  conv:destroy()
end

T["temporary conversations are not saved"] = function()
  local conv = conversation()
  conv.temporary = true
  eq(persistence.save(conv), true)
  eq(persistence.list(), {})
  conv:destroy()
end

T["list skips corrupt files and load rejects unsupported versions and unsafe IDs"] = function()
  local conv = conversation()
  conv:add_user_message("Hello")
  eq(persistence.save(conv), true)
  local dir = vim.fs.joinpath(root, "sia", "conversations")
  vim.fn.writefile({ "broken" }, dir .. "/corrupt.json")
  vim.fn.writefile(
    { vim.json.encode({ format = "sia.conversation", version = 2 }) },
    dir .. "/future.json"
  )
  local listed = persistence.list()
  eq(#listed, 1)
  eq(listed[1].id, conv.uuid)
  eq(listed[1].messages, nil)
  eq(persistence.load("future"), nil)
  eq(persistence.load("../escape"), nil)
  conv:destroy()
end

T["save failures leave the previous snapshot intact"] = function()
  local conv = conversation()
  conv:add_user_message("Hello")
  eq(persistence.save(conv), true)
  local rename = vim.uv.fs_rename
  vim.uv.fs_rename = function()
    return nil, "test failure"
  end
  conv:add_assistant_message("turn", "New response")
  local ok = persistence.save(conv)
  vim.uv.fs_rename = rename
  eq(ok, false)
  eq(#assert(persistence.load(conv.uuid)).messages, 1)
  eq(
    #vim.fn.glob(vim.fs.joinpath(root, "sia", "conversations", "*.tmp"), false, true),
    0
  )
  conv:destroy()
end

T["assistant saves request and final response only for chats"] = function()
  local common = require("sia.strategy.common").Strategy
  local chat = require("sia.strategy.chat")
  local mock = require("tests.mock")
  local conv = conversation()
  conv:add_user_message("Hello")
  conv:add_tool_message("turn", call(), "one-shot", { ephemeral = true })
  local strategy = common.new(conv)
  -- Exercise the chat persistence boundary without a live UI.
  for name, method in pairs(common) do
    if type(method) == "function" then
      strategy[name] = method
    end
  end
  setmetatable(strategy, chat)
  mock.mock_fn_jobstart({ { choices = { { delta = { content = "Answer" } } } } })
  local snapshots, save = {}, persistence.save
  persistence.save = function(c)
    snapshots[#snapshots + 1] = persistence.snapshot(c)
    return true
  end
  local ok, err = pcall(function()
    require("sia.assistant").execute_strategy(strategy)
    -- Auxiliary strategies and explicitly disabled persistence must not save.
    mock.mock_fn_jobstart({ { choices = { { delta = { content = "Auxiliary" } } } } })
    require("sia.assistant").execute_strategy(common.new(conv))
    local settings = require("sia.config").options.settings.persistence
    local enabled = settings.enable
    settings.enable = false
    local disabled_ok, disabled_err =
      pcall(require("sia.assistant").execute_strategy, strategy)
    settings.enable = enabled
    assert(disabled_ok, disabled_err)
  end)
  persistence.save = save
  mock.unmock_assistant()
  assert(ok, err)
  eq(#snapshots, 2)
  eq(snapshots[1].messages, { { role = "user", content = "Hello" } })
  eq(snapshots[2].messages, {
    { role = "user", content = "Hello" },
    { role = "assistant", content = "Answer" },
  })
  conv:destroy()
end

T["hidden user context survives serialization and restoration without reaching provider payloads"] = function()
  local conv = conversation()
  conv:add_user_message("Initial context", nil, { hide = true })
  conv:add_user_message("Visible question")
  local messages = conv:serialize()
  eq(messages[1].hide, true)
  eq(messages[2].hide, nil)
  local data = {}
  require("sia.provider.openai").completion.prepare_messages(
    data,
    conv.model.api_name,
    messages
  )
  eq(data.messages[1].hide, nil)
  eq(data.messages[1].content[1].text, "Initial context")
  eq(persistence.save(conv), true)
  local snapshot = assert(persistence.load(conv.uuid))
  eq(snapshot.messages[1].hide, true)
  local restored = assert(persistence.restore(conv.uuid))
  eq(restored.entries[1].hide, true)
  eq(restored.entries[2].hide, false)
  eq(restored.entries[1].content, "Initial context")
  restored:destroy()
  conv:destroy()
end

T["tool summaries round trip without live callbacks or provider metadata"] = function()
  local conv = conversation()
  local summaries = {
    "Read a file",
    false,
    {
      header = "Read files",
      detail = {
        { text = "first preview", ft = "lua" },
        { text = "second preview" },
      },
      on_activate = function() error("must not run") end,
    },
    { header = "Read file", detail = { text = "preview", ft = "lua" } },
  }
  for i, summary in ipairs(summaries) do
    conv:add_tool_message("turn", {
      id = "call-" .. i,
      type = "function",
      name = "view",
      arguments = "{}",
    }, "result", { summary = summary })
  end
  local messages = conv:serialize({ read_only = true })
  eq(messages[6].summary, summaries[3])
  local data = {}
  require("sia.provider.openai").completion.prepare_messages(data, conv.model.api_name, messages)
  for _, message in ipairs(data.messages) do
    eq(message.summary, nil)
  end
  eq(persistence.save(conv), true)
  local snapshot = assert(persistence.load(conv.uuid))
  eq(snapshot.messages[2].summary, "Read a file")
  eq(snapshot.messages[4].summary, false)
  eq(snapshot.messages[6].summary, {
    header = summaries[3].header,
    detail = summaries[3].detail,
  })
  eq(type(summaries[3].on_activate), "function")
  local restored = assert(persistence.restore(conv.uuid))
  for i = 1, #summaries do
    eq(restored.entries[i].summary, snapshot.messages[i * 2].summary)
  end
  conv:destroy()
  restored:destroy()
end

return T
