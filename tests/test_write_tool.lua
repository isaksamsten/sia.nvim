local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      child.restart({ "-u", "assets/minimal.lua" })
    end,
    post_once = function()
      child.stop()
    end,
  },
})

local eq = MiniTest.expect.equality

T["sia.tools.write"] = MiniTest.new_set()

T["sia.tools.write"]["creates new file with parent directory"] = function()
  local code = [[
    local write_tool = require("sia.tools.write")
    local utils = require("sia.utils")

    -- Mock mkdir to track if it was called
    local mkdir_calls = {}
    local original_mkdir = vim.fn.mkdir
    vim.fn.mkdir = function(path, flags)
      table.insert(mkdir_calls, { path = path, flags = flags })
      return original_mkdir(path, flags)
    end

    -- Create a temporary test directory
    local temp_dir = vim.fn.tempname()
    local test_file = temp_dir .. "/nested/dir/test.lua"

    local result = nil

    write_tool.execute({
      path = test_file,
      content = "print('hello')\nprint('world')",
    }, { auto_confirm_tools = { write = 1 } }, function(res)
      result = {
        content = res.content,
        display_content = res.display_content,
        kind = res.kind,
        context = {kind=res.context.kind},
      }
    end, {
      user_input = function(_, opts)
        opts.on_accept()
      end,
    })

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.mkdir_calls = mkdir_calls
    _G.file_exists = vim.fn.filereadable(test_file) == 1

    -- Cleanup
    vim.fn.delete(temp_dir, "rf")
    vim.fn.mkdir = original_mkdir
  ]]

  child.lua(code)

  local result = child.lua_get("_G.result")
  local mkdir_calls = child.lua_get("_G.mkdir_calls")
  local file_exists = child.lua_get("_G.file_exists")

  -- Verify mkdir was called with correct parameters
  eq(1, #mkdir_calls)
  eq("p", mkdir_calls[1].flags)

  -- Verify file was created successfully
  eq(true, file_exists)
  eq(
    "Successfully created buffer for "
      .. mkdir_calls[1].path:gsub("/nested/dir$", "")
      .. "/nested/dir/test.lua",
    result.content[1]
  )
  eq(true, string.find(result.display_content[1], "💾 Created.*test%.lua") ~= nil)
  eq("edit", result.context.kind)
end

T["sia.tools.write"]["creates new file without nested directories"] = function()
  local code = [[
    local write_tool = require("sia.tools.write")

    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    local test_file = temp_dir .. "/simple.lua"

    local result = nil

    write_tool.execute({
      path = test_file,
      content = "local x = 1",
    }, { auto_confirm_tools = { write = 1 } }, function(res)
      result = {
        content = res.content,
        display_content = res.display_content,
      }
    end, {
      user_input = function(_, opts)
        opts.on_accept()
      end,
    })

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.file_exists = vim.fn.filereadable(test_file) == 1

    -- Cleanup
    vim.fn.delete(temp_dir, "rf")
  ]]

  child.lua(code)

  local result = child.lua_get("_G.result")
  local file_exists = child.lua_get("_G.file_exists")

  eq(true, file_exists)
  eq(true, string.find(result.content[1], "Successfully created buffer") ~= nil)
  eq(true, string.find(result.display_content[1], "💾 Created") ~= nil)
end

T["sia.tools.write"]["overwrites existing file"] = function()
  local code = [[
    local write_tool = require("sia.tools.write")

    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    local test_file = temp_dir .. "/existing.lua"

    -- Create existing file
    vim.fn.writefile({ "old content" }, test_file)

    local result = nil

    write_tool.execute({
      path = test_file,
      content = "new content",
    }, { auto_confirm_tools = { write = 1 } }, function(res)
      result = {
        content = res.content,
        display_content = res.display_content,
      }
    end, {
      user_input = function(_, opts)
        opts.on_accept()
      end,
    })

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.new_content = vim.fn.readfile(test_file)

    -- Cleanup
    vim.fn.delete(temp_dir, "rf")
  ]]

  child.lua(code)

  local result = child.lua_get("_G.result")
  local new_content = child.lua_get("_G.new_content")

  eq({ "new content" }, new_content)
  eq(true, string.find(result.content[1], "Successfully overwritten buffer") ~= nil)
  eq(true, string.find(result.display_content[1], "💾 Overwrote") ~= nil)
end

T["sia.tools.write"]["handles missing path parameter"] = function()
  local code = [[
    local write_tool = require("sia.tools.write")

    local result = nil

    write_tool.execute({
      content = "some content",
    }, { auto_confirm_tools = { write = 1 } }, function(res)
      result = {
        content = res.content,
        display_content = res.display_content,
        kind = res.kind,
      }
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
  ]]

  child.lua(code)

  local result = child.lua_get("_G.result")

  eq("Error: No file path provided", result.content[1])
  eq("❌ Failed to write file", result.display_content[1])
  eq("failed", result.kind)
end

T["sia.tools.write"]["handles missing content parameter"] = function()
  local code = [[
    local write_tool = require("sia.tools.write")

    local result = nil

    write_tool.execute({
      path = "/tmp/test.lua",
    }, { auto_confirm_tools = { write = 1 } }, function(res)
      result = {
        content = res.content,
        display_content = res.display_content,
        kind = res.kind,
      }
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
  ]]

  child.lua(code)

  local result = child.lua_get("_G.result")

  eq("Error: No content provided", result.content[1])
  eq("❌ Failed to write file", result.display_content[1])
  eq("failed", result.kind)
end

T["sia.tools.write"]["handles multiline content correctly"] = function()
  local code = [[
    local write_tool = require("sia.tools.write")

    local temp_dir = vim.fn.tempname()
    vim.fn.mkdir(temp_dir, "p")
    local test_file = temp_dir .. "/multiline.lua"

    local result = nil

    write_tool.execute({
      path = test_file,
      content = "line 1\nline 2\nline 3",
    }, { auto_confirm_tools = { write = 1 } }, function(res)
      result = {
        display_content = res.display_content,
      }
    end, {
      user_input = function(_, opts)
        opts.on_accept()
      end,
    })

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.file_content = vim.fn.readfile(test_file)

    -- Cleanup
    vim.fn.delete(temp_dir, "rf")
  ]]

  child.lua(code)

  local result = child.lua_get("_G.result")
  local file_content = child.lua_get("_G.file_content")

  eq({ "line 1", "line 2", "line 3" }, file_content)
  eq(true, string.find(result.display_content[1], "%(3 lines%)") ~= nil)
end
T["sia.tools.write"]["tool metadata"] = function()
  local code = [[
    local write_tool = require("sia.tools.write")

    _G.name = write_tool.name
    _G.description = write_tool.description
    _G.required = write_tool.required
    _G.parameters = write_tool.parameters
  ]]

  child.lua(code)

  eq("write", child.lua_get("_G.name"))
  eq("Write complete file contents to a buffer", child.lua_get("_G.description"))

  local required = child.lua_get("_G.required")
  eq(true, vim.tbl_contains(required, "path"))
  eq(true, vim.tbl_contains(required, "content"))

  local parameters = child.lua_get("_G.parameters")
  eq("string", parameters.path.type)
  eq("string", parameters.content.type)
end

T["sia.tools.write"]["creates deeply nested directory structure"] = function()
  local code = [[
    local write_tool = require("sia.tools.write")

    local temp_dir = vim.fn.tempname()
    local test_file = temp_dir .. "/a/b/c/d/e/deep.lua"

    local result = nil

    write_tool.execute({
      path = test_file,
      content = "-- deeply nested file",
    }, { auto_confirm_tools = { write = 1 } }, function(res)
      result = {
        content = res.content,
      }
    end, {
      user_input = function(_, opts)
        opts.on_accept()
      end,
    })

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.file_exists = vim.fn.filereadable(test_file) == 1
    _G.dir_exists = vim.fn.isdirectory(temp_dir .. "/a/b/c/d/e") == 1

    -- Cleanup
    vim.fn.delete(temp_dir, "rf")
  ]]

  child.lua(code)

  local result = child.lua_get("_G.result")
  local file_exists = child.lua_get("_G.file_exists")
  local dir_exists = child.lua_get("_G.dir_exists")

  eq(true, dir_exists)
  eq(true, file_exists)
  eq(true, string.find(result.content[1], "Successfully created buffer") ~= nil)
end

return T
