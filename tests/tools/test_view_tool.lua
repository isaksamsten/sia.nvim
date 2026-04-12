local view_tool = require("sia.tools.view")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.tools.view"] = MiniTest.new_set()

local function create_test_buffer(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function mock_file_loader(buf, path_override)
  local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
  local original_filereadable = vim.fn.filereadable

  utils.ensure_file_is_loaded = function(path)
    if path_override and path == path_override then
      return buf
    elseif not path_override then
      return buf
    end
    return original_ensure_file_is_loaded(path)
  end

  vim.fn.filereadable = function(path)
    if path_override and path == path_override then
      return 1
    elseif not path_override then
      return 1
    end
    return original_filereadable(path)
  end

  return function()
    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
    vim.fn.filereadable = original_filereadable
  end
end

local function mock_tracker()
  local original_ensure_tracked = tracker.ensure_tracked
  tracker.ensure_tracked = function(_)
    return 1
  end
  return function()
    tracker.ensure_tracked = original_ensure_tracked
  end
end

local function create_mock_conversation()
  return {
    approved_tools = setmetatable({}, {__index = function() return true end}),
    
  }
end

local function create_execution_context()
  return {
    conversation = create_mock_conversation(),
  }
end

T["sia.tools.view"]["view text file basic"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3" })
  local restore_file_loader = mock_file_loader(buf, "test.txt")
  local restore_tracker = mock_tracker()

  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    path = "test.txt",
  }

  view_tool.implementation.execute(args, callback, create_execution_context())

  local content = type(result.content) == "string" and vim.split(result.content, "\n") or result.content
  eq(3, #content)
  eq("     1\tline 1", content[1])
  eq("     2\tline 2", content[2])
  eq("     3\tline 3", content[3])
  eq("📖 Viewed test.txt (3 lines)", result.summary)

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.view"]["skill files use the normal file summary"] = function()
  local skill_path = ".sia/skills/example/SKILL.md"
  local buf = create_test_buffer({ "# Skill" })
  local restore_file_loader = mock_file_loader(buf, skill_path)
  local restore_tracker = mock_tracker()

  local result = nil
  local callback = function(res)
    result = res
  end

  view_tool.implementation.execute({ path = skill_path }, callback, create_execution_context())

  eq("📖 Viewed .sia/skills/example/SKILL.md (1 lines)", result.summary)

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.view"]["view text file with offset and limit"] = function()
  local buf = create_test_buffer({ "line 1", "line 2", "line 3", "line 4", "line 5" })
  local restore_file_loader = mock_file_loader(buf, "test.txt")
  local restore_tracker = mock_tracker()

  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    path = "test.txt",
    offset = 2,
    limit = 2,
  }

  view_tool.implementation.execute(args, callback, create_execution_context())

  local content = type(result.content) == "string" and vim.split(result.content, "\n") or result.content
  eq(2, #content)
  eq("     2\tline 2", content[1])
  eq("     3\tline 3", content[2])
  eq("📖 Viewed lines 2-3 from test.txt", result.summary)

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.view"]["missing path parameter"] = function()
  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {}

  view_tool.implementation.execute(args, callback, create_execution_context())

  local content = type(result.content) == "string" and vim.split(result.content, "\n") or result.content
  eq("Error: No file path was provided", content[1])
  eq("❌ Failed to view", result.summary)
end

T["sia.tools.view"]["file not found"] = function()
  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    path = "nonexistent.txt",
  }

  view_tool.implementation.execute(args, callback, create_execution_context())

  local content = type(result.content) == "string" and vim.split(result.content, "\n") or result.content
  eq("Error: File cannot be found", content[1])
  eq("❌ Failed to view", result.summary)
end

T["sia.tools.view"]["offset beyond end of file"] = function()
  local buf = create_test_buffer({ "line 1", "line 2" })
  local restore_file_loader = mock_file_loader(buf, "test.txt")
  local restore_tracker = mock_tracker()

  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    path = "test.txt",
    offset = 10,
  }

  view_tool.implementation.execute(args, callback, create_execution_context())

  -- With offset beyond end of file, the view tool clamps to the last line
  -- and returns the content from that line
  local content = type(result.content) == "string" and vim.split(result.content, "\n") or result.content
  eq(1, #content)
  eq("     2\tline 2", content[1])

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.view"]["tool metadata"] = function()
  eq("view", view_tool.definition.name)
  eq("Views a file from the local filesystem.", view_tool.definition.description)

  local required = view_tool.definition.required
  eq(true, vim.tbl_contains(required, "path"))

  eq("string", view_tool.definition.parameters.path.type)
  eq("integer", view_tool.definition.parameters.offset.type)
  eq("integer", view_tool.definition.parameters.limit.type)
end

return T

