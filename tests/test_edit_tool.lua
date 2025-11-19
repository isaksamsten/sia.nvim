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

T["sia.tools.edit"] = MiniTest.new_set()

T["sia.tools.edit"]["successful exact match edit multiple changes"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    -- Create test buffer
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "function hello()",
      "  print('world')",
      "end",
      "other code"
    })

    -- Mock file loader
    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_)
      return buf
    end

    local result = nil
    local callback = function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end

    local args = {
      target_file = "test.lua",
      old_string = "  print('world')\nend",
      new_string = "  print('world')\nend\n\nfunction(test)\n  print(test)\nend",
    }

    local conversation = {
      auto_confirm_tools = { edit = 1 },
    }

    edit_tool.execute(args, conversation, callback, nil)

    vim.wait(2000, function() return result ~= nil end)

    local new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    _G.result = result
    _G.new_content = new_content

    -- Restore
    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")
  local new_content = child.lua_get("_G.new_content")

  eq("function hello()", new_content[1])
  eq("  print('world')", new_content[2])
  eq("end", new_content[3])
  eq("", new_content[4])
  eq("  print(test)", new_content[6])

  eq("edit", result.kind)
  eq("Edited test.lua:", result.content[1])
  eq("+  print(test)", result.content[7])
end

T["sia.tools.edit"]["successful exact match edit"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "function hello()",
      "  print('world')",
      "end",
      "other code"
    })

    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result = nil

    local args = {
      target_file = "test.lua",
      old_string = "function hello()\n  print('world')\nend",
      new_string = "function hello()\n  print('universe')\nend",
    }

    edit_tool.execute(args, { auto_confirm_tools = { edit = 1 } }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")
  local new_content = child.lua_get("_G.new_content")

  eq("function hello()", new_content[1])
  eq("  print('universe')", new_content[2])
  eq("end", new_content[3])
  eq("other code", new_content[4])

  eq("edit", result.kind)
  eq("Edited test.lua:", result.content[1])
  eq(
    true,
    string.find(result.display_content[1], "✏️ Edited lines 1%-3 in test%.lua")
      ~= nil
  )
end

T["sia.tools.edit"]["successful inline edit"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world isak" })

    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result = nil

    edit_tool.execute({
      target_file = "test.txt",
      old_string = "isak",
      new_string = "lisa",
    }, { auto_confirm_tools = { edit = 1 } }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")
  local new_content = child.lua_get("_G.new_content")

  eq("hello world lisa", new_content[1])
  eq("edit", result.kind)
  eq(
    true,
    string.find(
      result.display_content[1],
      "✏️ Edited line 1 %(columns 13%-16%) in test%.txt"
    ) ~= nil
  )
end

T["sia.tools.edit"]["successful edit with line numbers stripped"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "function test()", "  return true", "end" })

    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result = nil

    edit_tool.execute({
      target_file = "test.lua",
      old_string = "    1\tfunction test()\n    2\t  return true\n    3\tend",
      new_string = "    1\tfunction test()\n    2\t  return false\n    3\tend",
    }, { auto_confirm_tools = { edit = 1 } }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")
  local new_content = child.lua_get("_G.new_content")

  eq("function test()", new_content[1])
  eq("  return false", new_content[2])
  eq("end", new_content[3])

  eq("edit", result.kind)
  eq(true, string.find(result.content[1], "the match was not perfect") ~= nil)
  eq(
    true,
    string.find(result.display_content[1], "please double%-check the changes") ~= nil
  )
end

T["sia.tools.edit"]["create new file"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})

    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result = nil

    edit_tool.execute({
      target_file = "new_file.lua",
      old_string = "",
      new_string = "print('hello world')",
    }, { auto_confirm_tools = { edit = 1 } }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")
  local new_content = child.lua_get("_G.new_content")

  eq("print('hello world')", new_content[1])
  eq("edit", result.kind)
  eq("Edited new_file.lua:", result.content[1])
end

T["sia.tools.edit"]["auto confirm for AGENTS.md"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Agents", "Some content" })

    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result = nil

    edit_tool.execute({
      target_file = "AGENTS.md",
      old_string = "Some content",
      new_string = "Updated content",
    }, { auto_confirm_tools = {} }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result

    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  eq("edit", result.kind)
end

T["sia.tools.edit"]["auto confirm for .sia/memory/file.md"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "# Agents", "Some content" })

    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result = nil

    edit_tool.execute({
      target_file = ".sia/memory/test.md",
      old_string = "Some content",
      new_string = "Updated content",
    }, { auto_confirm_tools = {} }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result

    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  eq("edit", result.kind)
end

T["sia.tools.edit"]["missing target_file parameter"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")

    local result = nil

    edit_tool.execute({
      old_string = "test",
      new_string = "updated",
    }, { auto_confirm_tools = { edit = 1 } }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  eq("Error: No target_file was provided", result.content[1])
  eq("❌ Failed to edit", result.display_content[1])
end

T["sia.tools.edit"]["missing old_string parameter"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")

    local result = nil

    edit_tool.execute({
      target_file = "test.lua",
      new_string = "updated",
    }, { auto_confirm_tools = { edit = 1 } }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  eq("Error: No old_string was provided", result.content[1])
  eq("❌ Failed to edit", result.display_content[1])
end

T["sia.tools.edit"]["missing new_string parameter"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")

    local result = nil

    edit_tool.execute({
      target_file = "test.lua",
      old_string = "test",
    }, { auto_confirm_tools = { edit = 1 } }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  eq("Error: No new_string was provided", result.content[1])
  eq("❌ Failed to edit", result.display_content[1])
end

T["sia.tools.edit"]["file cannot be loaded"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return nil end

    local result = nil

    edit_tool.execute({
      target_file = "nonexistent.lua",
      old_string = "test",
      new_string = "updated",
    }, { auto_confirm_tools = { edit = 1 } }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result

    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  eq("Error: Cannot load nonexistent.lua", result.content[1])
  eq("❌ Failed to edit", result.display_content[1])
end

T["sia.tools.edit"]["no matches found"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })

    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result = nil

    edit_tool.execute({
      target_file = "test.txt",
      old_string = "nonexistent",
      new_string = "updated",
    }, { auto_confirm_tools = { edit = 1 } }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result

    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  eq(true, string.find(result.content[1], "Failed to edit test.txt") ~= nil)
  eq("❌ Failed to edit test.txt", result.display_content[1])
end

T["sia.tools.edit"]["multiple matches found"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "test line", "another test line", "final test" })

    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result = nil

    edit_tool.execute({
      target_file = "test.txt",
      old_string = "test",
      new_string = "updated",
    }, { auto_confirm_tools = { edit = 1 } }, function(res)
      result = {display_content=res.display_content,kind=res.kind, content=res.content}
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result

    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  eq(
    true,
    string.find(
      result.content[1],
      "Failed to edit test%.txt since I couldn't find the exact text to replace"
    ) ~= nil
  )
  eq(
    true,
    string.find(result.content[1], "found multiple matches instead of exactly one")
      ~= nil
  )
  eq("❌ Failed to edit test.txt", result.display_content[1])
end

T["sia.tools.edit"]["max failed matches reached"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })

    local original_ensure_file_is_loaded = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local results = {}

    local args = {
      target_file = "test.txt",
      old_string = "nonexistent",
      new_string = "updated",
    }

    edit_tool.execute(args, { auto_confirm_tools = { edit = 1 } }, function(res)
      table.insert(results, res)
    end, nil)

    vim.wait(2000, function() return #results > 0 end)

    edit_tool.execute(args, { auto_confirm_tools = { edit = 1 } }, function(res)
      table.insert(results, res)
    end, nil)

    vim.wait(2000, function() return #results > 1 end)

    edit_tool.execute(args, { auto_confirm_tools = { edit = 1 } }, function(res)
      table.insert(results, res)
    end, nil)

    vim.wait(2000, function() return #results > 2 end)

    _G.results = results

    utils.ensure_file_is_loaded = original_ensure_file_is_loaded
  ]]

  child.lua(code)
  local results = child.lua_get("_G.results")

  local final_result = results[3]
  eq(
    true,
    string.find(final_result.content[1], "Edit failed because no matches were found")
      ~= nil
  )
  eq(
    true,
    string.find(final_result.content[1], "let the user manually make the change") ~= nil
  )
end

T["sia.tools.edit"]["tool metadata"] = function()
  local code = [[
    local edit_tool = require("sia.tools.edit")

    local args = {
      target_file = "test.txt",
      old_string = "nonexistent",
      new_string = "updated",
    }

    _G.name = edit_tool.name
    _G.description = edit_tool.description
    _G.message = edit_tool.message(args)
    _G.required = edit_tool.required
    _G.parameters = edit_tool.parameters
  ]]

  child.lua(code)

  eq("edit", child.lua_get("_G.name"))
  eq("Tool for editing files", child.lua_get("_G.description"))
  eq("Making changes to test.txt...", child.lua_get("_G.message"))

  local required = child.lua_get("_G.required")
  eq(true, vim.tbl_contains(required, "target_file"))
  eq(true, vim.tbl_contains(required, "old_string"))
  eq(true, vim.tbl_contains(required, "new_string"))

  local parameters = child.lua_get("_G.parameters")
  eq("string", parameters.target_file.type)
  eq("string", parameters.old_string.type)
  eq("string", parameters.new_string.type)
end

return T
