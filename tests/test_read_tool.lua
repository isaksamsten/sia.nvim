local read_tool = require("sia.tools.read")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.tools.read"] = MiniTest.new_set()

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
    auto_confirm_tools = {},
    ignore_tool_confirm = true,
  }
end

local function create_mock_opts()
  return {
    user_input = function(_, opts)
      opts.on_accept()
    end,
  }
end

T["sia.tools.read"]["read text file basic"] = function()
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

  read_tool.execute(args, create_mock_conversation(), callback, create_mock_opts())

  eq("context", result.kind)
  eq(3, #result.content)
  eq("     1\tline 1", result.content[1])
  eq("     2\tline 2", result.content[2])
  eq("     3\tline 3", result.content[3])
  eq("📖 Read test.txt (3 lines)", result.display_content[1])

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.read"]["read text file with offset and limit"] = function()
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

  read_tool.execute(args, create_mock_conversation(), callback, create_mock_opts())

  eq("context", result.kind)
  eq(2, #result.content)
  eq("     2\tline 2", result.content[1])
  eq("     3\tline 3", result.content[2])
  eq("📖 Read lines 2-3 from test.txt", result.display_content[1])

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.read"]["missing path parameter"] = function()
  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {}

  read_tool.execute(args, create_mock_conversation(), callback, create_mock_opts())

  eq("Error: No file path was provided", result.content[1])
  eq("❌ Failed to read", result.display_content[1])
end

T["sia.tools.read"]["file not found"] = function()
  local result = nil
  local callback = function(res)
    result = res
  end

  local args = {
    path = "nonexistent.txt",
  }

  read_tool.execute(args, create_mock_conversation(), callback, create_mock_opts())

  eq("Error: File cannot be found", result.content[1])
  eq("❌ Failed to read", result.display_content[1])
end

T["sia.tools.read"]["offset beyond end of file"] = function()
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

  read_tool.execute(args, create_mock_conversation(), callback, create_mock_opts())

  eq(true, vim.startswith(result.content[1], "Error: Offset 10 is beyond end of file"))
  eq("❌ Failed to read", result.display_content[1])

  restore_file_loader()
  restore_tracker()
end

T["sia.tools.read"]["tool metadata"] = function()
  eq("read", read_tool.name)
  eq("Reads a file from the local filesystem.", read_tool.description)

  eq("Reading file contents...", read_tool.message)

  local required = read_tool.required
  eq(true, vim.tbl_contains(required, "path"))

  eq("string", read_tool.parameters.path.type)
  eq("integer", read_tool.parameters.offset.type)
  eq("integer", read_tool.parameters.limit.type)
end

return T
