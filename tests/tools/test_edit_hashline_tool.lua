local eq = MiniTest.expect.equality
local tool = require("sia.tools.edit")
local view = require("sia.tools.view")
local path, conversation, tag, buf
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      path = vim.fn.tempname()
      vim.fn.writefile({ "one", "two", "three" }, path)
      conversation = {
        approved_tools = { view = true, edit = true },
        tracker = {
          suppress = function(_, _, fn)
            fn()
          end,
        },
      }
      local result
      view.implementation.execute({ path = path }, function(res)
        result = res
      end, { conversation = conversation })
      tag = result.content:match("#(%x+)%]")
      buf = vim.fn.bufnr(path)
    end,
    post_case = function()
      if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
      vim.fn.delete(path)
    end,
  },
})
local function execute(edits, snapshot)
  local result
  tool.implementation.execute(
    { target_file = path, tag = snapshot or tag, edits = edits },
    function(res)
      result = res
    end,
    { conversation = conversation }
  )
  return result
end
T["view provides tag and edits save to disk"] = function()
  eq(type(tag), "string")
  local result = execute("PUT 2.=2:\n+changed\nCUT 3.=3")
  eq(result.ephemeral, nil)
  eq(vim.fn.readfile(path), { "one", "changed" })
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "changed" })
  local rejected = execute("CUT 1.=1")
  eq(rejected.ephemeral, nil)
  require("sia.tool_output").complete(rejected)
  eq(type(rejected.summary.detail), "table")
  eq(type(rejected.region), "table")
  eq(rejected.content:find("supplied tag", 1, true) ~= nil, true)
end
T["invalid batch never writes partial changes"] = function()
  local result = execute("CUT 1.=1\nCUT 4.=4")
  eq(result.ephemeral, true)
  eq(true, result.summary:find("Failed", 1, true) ~= nil)
  require("sia.tool_output").complete(result)
  eq(type(result.summary.detail), "table")
  eq(vim.fn.readfile(path), { "one", "two", "three" })
end
T["unsaved buffer changes return recovery context"] = function()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "user edit" })
  local rejected = execute("CUT 1.=1")
  eq(rejected.ephemeral, nil)
  eq(type(rejected.region), "table")
  eq(rejected.content:find("Buffer contents changed", 1, true) ~= nil, true)
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false), { "user edit" })
end
T["saved external changes return fresh context and reset old read coverage"] = function()
  local lines = {}
  for i = 1, 100 do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.fn.writefile(lines, path)
  local original_tag =
    require("sia.hashline").view(conversation, path, lines, 1, 100)[1]:match("#(%x+)%]")
  lines[20] = "partner changed this"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.fn.writefile(lines, path)
  local result = execute("PUT 20.=20:\n+replacement", original_tag)
  eq(result.ephemeral, nil)
  eq(result.content:find("Buffer contents changed", 1, true) ~= nil, true)
  eq(result.content:find("20:partner changed this", 1, true) ~= nil, true)
  eq(vim.fn.readfile(path), lines)
  local fresh = result.content:match("#(%x+)%]")
  eq(type(fresh), "string")
  eq(require("sia.hashline").apply(conversation, path, lines, fresh, "CUT 90.=90"), nil)
  local retry = execute("PUT 20.=20:\n+replacement", fresh)
  eq(retry.ephemeral, nil)
  eq(vim.fn.readfile(path)[20], "replacement")
end
T["recovery preview is invalidated by the conversation tracker"] = function()
  conversation.tracker = require("sia.tracker").new()
  local result = execute("CUT 1.=1", "invalid")
  eq(result.region.pos, { 1, 3 })
  local tick = conversation.tracker:track(buf, result.region.pos)
  eq(conversation.tracker:is_stale(buf, tick, result.region.pos), false)
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "inserted" })
  eq(conversation.tracker:is_stale(buf, tick, result.region.pos), true)
  conversation.tracker:destroy()
end
T["edits preserve unsaved user changes after a fresh view"] = function()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "unsaved user edit" })
  local result = execute("CUT 3.=3")
  eq(result.ephemeral, nil)
  local fresh = result.content:match("#(%x+)%]")
  local retry = execute("PUT 2.=2:\n+agent edit", fresh)
  eq(retry.ephemeral, nil)
  eq(vim.fn.readfile(path), { "unsaved user edit", "agent edit", "three" })
end
T["edits use buffer contents when disk differed before approval"] = function()
  vim.fn.writefile({ "external disk edit" }, path)
  local result = execute("CUT 1.=1")
  eq(result.ephemeral, nil)
  eq(vim.fn.readfile(path), { "two", "three" })
end
T["unknown snapshots return current context without applying the request"] = function()
  conversation = { approved_tools = { edit = true }, tracker = conversation.tracker }
  local result = execute("CUT 1.=1")
  eq(result.content:find("No recorded snapshot", 1, true) ~= nil, true)
  eq(result.ephemeral, nil)
  eq(vim.fn.readfile(path), { "one", "two", "three" })
  local fresh = result.content:match("#(%x+)%]")
  local retry = execute("CUT 1.=1", fresh)
  eq(retry.ephemeral, nil)
  eq(vim.fn.readfile(path), { "two", "three" })
end
T["recovery previews bound bytes and leave omitted and truncated lines unseen"] = function()
  local lines = {}
  for i = 1, 100 do
    lines[i] = string.rep("x", 2500)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.fn.writefile(lines, path)
  local result = execute("CUT 80.=80")
  eq(#result.content < 8500, true)
  eq(result.content:find("[TRUNCATED]", 1, true) ~= nil, true)
  local fresh = result.content:match("#(%x+)%]")
  eq(require("sia.hashline").apply(conversation, path, lines, fresh, "CUT 80.=80"), nil)
  eq(require("sia.hashline").apply(conversation, path, lines, fresh, "CUT 1.=1"), nil)
end
T["tool respects deny rules"] = function()
  conversation.active_mode = require("sia.permissions").create_active_mode("plan", {
    permissions = { deny = { "edit" } },
  })
  local result = execute("CUT 1.=1")
  eq(vim.fn.readfile(path), { "one", "two", "three" })
  eq(type(result.content), "table")
end
local function stage()
  -- Capture the runner to exercise delayed approval without opening a UI.
  local tool_utils = require("sia.tools.utils")
  local original = tool_utils.new_tool
  tool_utils.new_tool = function(_, runner)
    return runner
  end
  local ok, runner = pcall(dofile, "lua/sia/tools/edit/hashline.lua")
  tool_utils.new_tool = original
  assert(ok, runner)
  local pending, result
  runner(
    { target_file = path, tag = tag, edits = "CUT 1.=1" },
    conversation,
    function(res)
      result = res
    end,
    {
      user_input = function(_, opts)
        pending = opts
      end,
    }
  )
  return pending, function()
    return result
  end
end
T["preview renders the proposed change"] = function()
  local pending = stage()
  local preview = vim.api.nvim_create_buf(false, true)
  eq(pending.preview(preview) > 0, true)
  eq(vim.bo[preview].ft, "diff")
  local text = table.concat(vim.api.nvim_buf_get_lines(preview, 0, -1, false), "\n")
  eq(text:find("-one", 1, true) ~= nil, true)
  vim.api.nvim_buf_delete(preview, { force = true })
end
T["buffer changes during approval prevent writes"] = function()
  local pending, result = stage()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "user edit" })
  pending.on_accept()
  eq(result().ephemeral, nil)
  eq(type(result().region), "table")
  eq(vim.fn.readfile(path), { "one", "two", "three" })
end
T["edit and undo during approval does not reject identical contents"] = function()
  local pending, result = stage()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "temporary" })
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "one" })
  pending.on_accept()
  eq(result().ephemeral, nil)
  eq(vim.fn.readfile(path), { "two", "three" })
end
T["saved changes during approval return tracked recovery context"] = function()
  local pending, result = stage()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "partner edit" })
  vim.fn.writefile({ "partner edit", "two", "three" }, path)
  pending.on_accept()
  eq(result().ephemeral, nil)
  eq(type(result().region), "table")
  eq(result().content:find("while awaiting approval", 1, true) ~= nil, true)
  eq(vim.fn.readfile(path), { "partner edit", "two", "three" })
end
T["disk changes during approval prevent writes"] = function()
  local pending, result = stage()
  vim.fn.writefile({ "external edit" }, path)
  pending.on_accept()
  eq(result().ephemeral, true)
  eq(vim.fn.readfile(path), { "external edit" })
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "one", "two", "three" })
end
T["file deletion during approval prevents writes"] = function()
  local pending, result = stage()
  vim.fn.delete(path)
  pending.on_accept()
  eq(result().ephemeral, true)
  eq(vim.fn.filereadable(path), 0)
end
T["view always returns hashline output"] = function()
  local result
  view.implementation.execute({ path = path, hashline = true }, function(res)
    result = res
  end, { conversation = conversation })
  eq(result.content:match("#(%x+)%]"), tag)
  eq(view.definition.parameters.hashline, nil)
end
T["conversation uses hashline tools"] = function()
  local conv = require("sia.conversation").new({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
    tools = { tool, view },
    approved_tools = { edit = true, view = true },
  })
  local selected_edit = conv.tool_implementation.edit
  local selected_view = conv.tool_implementation.view
  eq(conv.tool_definitions[1].parameters.tag.type, "string")
  eq(conv.tool_definitions[1].parameters.old_string, nil)
  local result
  selected_view.execute({ path = path }, function(res)
    result = res
  end, { conversation = conv })
  local snapshot = result.content:match("#(%x+)%]")
  eq(type(snapshot), "string")
  selected_edit.execute(
    { target_file = path, tag = snapshot, edits = "PUT 2.=2:\n+new" },
    function(res)
      result = res
    end,
    { conversation = conv }
  )
  eq(result.ephemeral, nil)
  eq(vim.fn.readfile(path), { "one", "new", "three" })
end
return T
