local eq = MiniTest.expect.equality
local tool = require("sia.tools.edit")
local view = require("sia.tools.view")
local path, conversation, tag, buf, original_hashline
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      original_hashline = require("sia.config").options.settings.hashline
      require("sia.config").options.settings.hashline = true
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
      require("sia.config").options.settings.hashline = original_hashline
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
  eq(execute("CUT 1.=1").ephemeral, true)
end
T["invalid batch never writes partial changes"] = function()
  eq(execute("CUT 1.=1\nCUT 4.=4").ephemeral, true)
  eq(vim.fn.readfile(path), { "one", "two", "three" })
end
T["buffer changes invalidate snapshot"] = function()
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "user edit" })
  eq(execute("CUT 1.=1").ephemeral, true)
  eq(vim.api.nvim_buf_get_lines(buf, 0, 1, false), { "user edit" })
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
  eq(result().ephemeral, true)
  eq(vim.fn.readfile(path), { "one", "two", "three" })
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
T["view output follows config instead of a tool argument"] = function()
  require("sia.config").options.settings.hashline = false
  local result
  view.implementation.execute({ path = path, hashline = true }, function(res)
    result = res
  end, { conversation = conversation })
  eq(result.content, "     1\tone\n     2\ttwo\n     3\tthree")
  eq(view.definition.parameters.hashline, nil)
end
T["conversation retains selected tools after config changes"] = function()
  local conv = require("sia.conversation").new({
    temporary = true,
    model = require("sia.model").resolve("openai/gpt-4.1"),
    tools = { tool, view },
    approved_tools = { edit = true, view = true },
  })
  local selected_edit = conv.tool_implementation.edit
  local selected_view = conv.tool_implementation.view
  require("sia.config").options.settings.hashline = false
  eq(conv.tool_definitions[1].parameters.tag.type, "string")
  eq(conv.tool_definitions[1].parameters.old_string, nil)
  eq(selected_edit.instructions:find("PUT N.=M:", 1, true) ~= nil, true)
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
