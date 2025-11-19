local test_dir = vim.fn.tempname() .. "_glob_test"
local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      vim.fn.mkdir(test_dir, "p")

      -- Create directory structure
      vim.fn.mkdir(test_dir .. "/src", "p")
      vim.fn.mkdir(test_dir .. "/src/lua", "p")
      vim.fn.mkdir(test_dir .. "/src/python", "p")
      vim.fn.mkdir(test_dir .. "/tests", "p")
      vim.fn.mkdir(test_dir .. "/.hidden", "p")

      -- Create files
      vim.fn.writefile({}, test_dir .. "/README.md")
      vim.fn.writefile({}, test_dir .. "/main.lua")
      vim.fn.writefile({}, test_dir .. "/config.json")
      vim.fn.writefile({}, test_dir .. "/src/init.lua")
      vim.fn.writefile({}, test_dir .. "/src/utils.lua")
      vim.fn.writefile({}, test_dir .. "/src/lua/parser.lua")
      vim.fn.writefile({}, test_dir .. "/src/lua/lexer.lua")
      vim.fn.writefile({}, test_dir .. "/src/python/main.py")
      vim.fn.writefile({}, test_dir .. "/src/python/utils.py")
      vim.fn.writefile({}, test_dir .. "/tests/test_main.lua")
      vim.fn.writefile({}, test_dir .. "/tests/test_utils.lua")
      vim.fn.writefile({}, test_dir .. "/.hidden/secret.txt")
      vim.fn.writefile({}, test_dir .. "/.gitignore")

      -- Set up child Neovim process using same approach as matcher tests
      child.restart({ "-u", "assets/minimal.lua" })
      child.fn.chdir(test_dir)
    end,
    post_once = function()
      child.stop()
      vim.fn.delete(test_dir, "rf")
    end,
  },
})
local eq = MiniTest.expect.equality

-- Helper function to check if files are present in result.content
local function contains_files(result, expected_files)
  local content_str = table.concat(result.content, "\n")
  for _, file in ipairs(expected_files) do
    if not content_str:find(file, 1, true) then
      return false, "Missing file: " .. file
    end
  end
  return true
end

T["sia.tools.glob"] = MiniTest.new_set()

T["sia.tools.glob"]["find all lua files"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      pattern = "*.lua",
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)

    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")
  eq(true, contains_files(result, { "main.lua" }))
end

T["sia.tools.glob"]["find all lua files recursively"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      pattern = "**/*.lua",
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)

    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  -- Should find all 7 lua files recursively
  eq(true, contains_files(result, {
    "main.lua",
    "src/init.lua",
    "src/utils.lua",
    "src/lua/parser.lua",
    "src/lua/lexer.lua",
    "tests/test_main.lua",
    "tests/test_utils.lua"
  }))
end

T["sia.tools.glob"]["find files in specific directory"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      pattern = "*.lua",
      path = "src",
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)


    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  eq(true, contains_files(result, { "src/init.lua", "src/utils.lua" }))
end

T["sia.tools.glob"]["find files in nested directory"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      pattern = "*.py",
      path = "src/python",
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)

    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  -- Should find python files in src/python directory
  eq(true, contains_files(result, { "src/python/main.py", "src/python/utils.py" }))
end

T["sia.tools.glob"]["list all files in directory without pattern"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      path = "tests",
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)

    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  -- Should list all files in tests directory
  eq(true, contains_files(result, { "tests/test_main.lua", "tests/test_utils.lua" }))
end

T["sia.tools.glob"]["find hidden files with flag"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      pattern = ".*",
      hidden = true,
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)


    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  -- Should find hidden files (gitignore is the only file matching .* pattern)
  eq(true, contains_files(result, { ".gitignore" }))
end

T["sia.tools.glob"]["find files in hidden directory"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      path = ".hidden",
      hidden = true,
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)


    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  -- Should find files in hidden directory
  eq(true, contains_files(result, { ".hidden/secret.txt" }))
end

T["sia.tools.glob"]["no matches returns appropriate message"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      pattern = "*.nonexistent",
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)

    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  -- Should return no matches message
  eq("No files found matching pattern: *.nonexistent", result.content[1])
end

T["sia.tools.glob"]["no matches in specific directory"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      pattern = "*.rs",
      path = "src",
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)

    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  -- Should return no matches message with path
  eq("No files found matching pattern: *.rs in src", result.content[1])
end

T["sia.tools.glob"]["multiple file extensions"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      pattern = "*.{lua,py}",
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)


    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  -- Should find both lua and py files
  eq(true, contains_files(result, {
    "main.lua",
    "src/init.lua",
    "src/utils.lua",
    "src/lua/parser.lua",
    "src/lua/lexer.lua",
    "tests/test_main.lua",
    "tests/test_utils.lua",
    "src/python/main.py",
    "src/python/utils.py"
  }))
end

T["sia.tools.glob"]["search in non-existent path"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      path = "nonexistent_directory",
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)

    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  -- Should return no files found message for non-existent path
  eq("No files found in nonexistent_directory", result.content[1])
end

T["sia.tools.glob"]["search with pattern in non-existent path"] = function()
  local code = [[
    local glob_tool = require("sia.tools.glob")
    local result = nil
    local callback = function(res)
      result = res
    end

    local args = {
      pattern = "*.lua",
      path = "does/not/exist",
    }

    glob_tool.execute(args, { auto_confirm_tools = {}, ignore_tool_confirm = true }, callback)

    vim.wait(1000, function()
      return result ~= nil
    end)


    _G.result = result
  ]]

  child.lua(code)
  local result = child.lua_get("_G.result")

  -- Should return no files found message with pattern and path
  eq("No files found matching pattern: *.lua in does/not/exist", result.content[1])
end

return T
