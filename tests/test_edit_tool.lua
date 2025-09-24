local edit_tool = require("sia.tools.edit")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.tools.edit"] = MiniTest.new_set()

local function create_test_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function mock_file_loader(buf)
  local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
  utils.ensure_file_is_loaded = function(_)
    return buf
  end
  return function()
    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  end
end

local function mock_tracker()
  local original_non_tracked_edit = tracker.non_tracked_edit
  local original_ensure_tracked = tracker.ensure_tracked
  tracker.non_tracked_edit = function(_, fn)
    fn()
  end
  tracker.ensure_tracked = function(_)
    return 1
  end
  return function()
    tracker.non_tracked_edit = original_non_tracked_edit
    tracker.ensure_tracked = original_ensure_tracked
  end
end

local function create_mock_conversation(auto_confirm_edit)
  return {
    auto_confirm_tools = {
      edit = auto_confirm_edit,
    },
  }
end

T["sia.tools.edit"]["successful exact match edit"] = function()
  local buf = create_test_buffer({ "function hello()", "  print('world')", "end", "other code" })
  local restore_file_loader = mock_file_loader(buf)
  local restore_tracker = mock_tracker()

  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    target_file = "test.lua",
    old_string = "function hello()\n  print('world')\nend",
    new_string = "function hello()\n  print('universe')\nend",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  local new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq("function hello()", new_content[1])
  eq("  print('universe')", new_content[2])
  eq("end", new_content[3])
  eq("other code", new_content[4])

  eq("edit", result.kind)
  eq(
    true,
    vim.tbl_contains(result.content, "Successfully edited test.lua. Here`s the edited snippet as returned by cat -n:")
  )
  eq(true, string.find(result.display_content[1], "✏️ Edited lines 1%-3 in test%.lua") ~= nil)

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.edit"]["successful inline edit"] = function()
  local buf = create_test_buffer({ "hello world isak" })
  local restore_file_loader = mock_file_loader(buf)
  local restore_tracker = mock_tracker()

  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    target_file = "test.txt",
    old_string = "isak",
    new_string = "lisa",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  local new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq("hello world lisa", new_content[1])

  eq("edit", result.kind)
  eq(true, string.find(result.display_content[1], "✏️ Edited line 1 %(columns 13%-16%) in test%.txt") ~= nil)

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.edit"]["successful edit with line numbers stripped"] = function()
  local buf = create_test_buffer({ "function test()", "  return true", "end" })
  local restore_file_loader = mock_file_loader(buf)
  local restore_tracker = mock_tracker()

  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    target_file = "test.lua",
    old_string = "    1\tfunction test()\n    2\t  return true\n    3\tend",
    new_string = "    1\tfunction test()\n    2\t  return false\n    3\tend",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  local new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq("function test()", new_content[1])
  eq("  return false", new_content[2])
  eq("end", new_content[3])

  eq("edit", result.kind)
  eq(true, string.find(result.content[1], "the match was not perfect") ~= nil)
  eq(true, string.find(result.display_content[1], "please double%-check the changes") ~= nil)

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.edit"]["create new file"] = function()
  local buf = create_test_buffer({})
  local restore_file_loader = mock_file_loader(buf)
  local restore_tracker = mock_tracker()

  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    target_file = "new_file.lua",
    old_string = "",
    new_string = "print('hello world')",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  local new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  eq("print('hello world')", new_content[1])

  eq("edit", result.kind)
  eq(
    true,
    vim.tbl_contains(
      result.content,
      "Successfully edited new_file.lua. Here`s the edited snippet as returned by cat -n:"
    )
  )

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.edit"]["auto confirm for AGENTS.md"] = function()
  local buf = create_test_buffer({ "# Agents", "Some content" })
  local restore_file_loader = mock_file_loader(buf)
  local restore_tracker = mock_tracker()

  local args = {
    target_file = "AGENTS.md",
    old_string = "Some content",
    new_string = "Updated content",
  }

  local result
  local auto_apply_result = edit_tool.execute(args, create_mock_conversation(nil), function(res)
    result = res
  end)
  eq("edit", result.kind)

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.edit"]["missing target_file parameter"] = function()
  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    old_string = "test",
    new_string = "updated",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  eq("Error: No target_file was provided", result.content[1])
  eq("❌ Failed to edit", result.display_content[1])
end

T["sia.tools.edit"]["missing old_string parameter"] = function()
  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    target_file = "test.lua",
    new_string = "updated",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  eq("Error: No old_string was provided", result.content[1])
  eq("❌ Failed to edit", result.display_content[1])
end

T["sia.tools.edit"]["missing new_string parameter"] = function()
  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    target_file = "test.lua",
    old_string = "test",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  eq("Error: No new_string was provided", result.content[1])
  eq("❌ Failed to edit", result.display_content[1])
end

T["sia.tools.edit"]["file cannot be loaded"] = function()
  local restore_file_loader = mock_file_loader(nil)

  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    target_file = "nonexistent.lua",
    old_string = "test",
    new_string = "updated",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  eq("Error: Cannot load nonexistent.lua", result.content[1])
  eq("❌ Failed to edit", result.display_content[1])

  restore_file_loader()
end

T["sia.tools.edit"]["no matches found"] = function()
  local buf = create_test_buffer({ "hello world" })
  local restore_file_loader = mock_file_loader(buf)
  local restore_tracker = mock_tracker()

  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    target_file = "test.txt",
    old_string = "nonexistent",
    new_string = "updated",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  eq(true, string.find(result.content[1], "Failed to edit test.txt") ~= nil)
  eq("❌ Failed to edit test.txt", result.display_content[1])

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.edit"]["multiple matches found"] = function()
  local buf = create_test_buffer({ "test line", "another test line", "final test" })
  local restore_file_loader = mock_file_loader(buf)
  local restore_tracker = mock_tracker()

  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    target_file = "test.txt",
    old_string = "test",
    new_string = "updated",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  eq(
    true,
    string.find(result.content[1], "Failed to edit test%.txt since I couldn't find the exact text to replace") ~= nil
  )
  eq(true, string.find(result.content[1], "found 3 matches instead of 1") ~= nil)
  eq("❌ Failed to edit test.txt", result.display_content[1])

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.edit"]["max failed matches reached"] = function()
  local buf = create_test_buffer({ "hello world" })
  local restore_file_loader = mock_file_loader(buf)
  local restore_tracker = mock_tracker()

  local results = {}
  local callback = function(res)
    table.insert(results, res)
  end

  local args = {
    target_file = "test.txt",
    old_string = "nonexistent",
    new_string = "updated",
  }

  edit_tool.execute(args, create_mock_conversation(1), callback, nil)
  edit_tool.execute(args, create_mock_conversation(1), callback, nil)
  edit_tool.execute(args, create_mock_conversation(1), callback, nil)

  local final_result = results[3]
  eq(true, string.find(final_result.content[1], "Edit failed because 0 matches was found") ~= nil)
  eq(true, string.find(final_result.content[1], "let the user manually make the change") ~= nil)

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.edit"]["tool metadata"] = function()
  local args = {
    target_file = "test.txt",
    old_string = "nonexistent",
    new_string = "updated",
  }
  eq("edit", edit_tool.name)
  eq("Tool for editing files", edit_tool.description)
  eq("Making changes to test.txt...", edit_tool.message(args))

  local required = edit_tool.required
  eq(true, vim.tbl_contains(required, "target_file"))
  eq(true, vim.tbl_contains(required, "old_string"))
  eq(true, vim.tbl_contains(required, "new_string"))

  eq("string", edit_tool.parameters.target_file.type)
  eq("string", edit_tool.parameters.old_string.type)
  eq("string", edit_tool.parameters.new_string.type)
end

return T
