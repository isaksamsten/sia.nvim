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

T["sia.tools.replace_region"] = MiniTest.new_set()

T["sia.tools.replace_region"]["replaces a region with new text"] = function()
  local code = [[
    local tool = require("sia.tools.replace_region")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "one",
      "two",
      "three",
      "four",
    })

    local original = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result

    tool.execute({
      target_file = "test.txt",
      start_line = 2,
      end_line = 3,
      text = "TWO\nTHREE",
    }, { auto_confirm_tools = { replace_region = 1 } }, function(res)
      result = {
        kind = res.kind,
        content = res.content,
        display_content = res.display_content,
        context = { pos = res.context and res.context.pos },
      }
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    utils.ensure_file_is_loaded = original
  ]]

  child.lua(code)

  local result = child.lua_get("_G.result")
  local lines = child.lua_get("_G.lines")

  eq({ "one", "TWO", "THREE", "four" }, lines)

  eq("edit", result.kind)
  eq("Replaced lines 2-3 in test.txt", result.content[1])
  eq(true, string.find(result.display_content[1], "Replaced lines 2%-3 in test%.txt") ~= nil)
  eq({ 2, 3 }, result.context.pos)
end

T["sia.tools.replace_region"]["deletes a region when text is empty"] = function()
  local code = [[
    local tool = require("sia.tools.replace_region")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "one",
      "two",
      "three",
      "four",
    })

    local original = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result

    tool.execute({
      target_file = "test.txt",
      start_line = 2,
      end_line = 3,
      text = "",
    }, { auto_confirm_tools = { replace_region = 1 } }, function(res)
      result = {
        kind = res.kind,
        content = res.content,
        context = { pos = res.context and res.context.pos },
      }
    end, nil)

    vim.wait(2000, function() return result ~= nil end)

    _G.result = result
    _G.lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    utils.ensure_file_is_loaded = original
  ]]

  child.lua(code)

  local result = child.lua_get("_G.result")
  local lines = child.lua_get("_G.lines")

  eq({ "one", "four" }, lines)
  eq("edit", result.kind)
  -- #new_lines == 0 => edit_end becomes start_line - 1
  eq({ 2, 1 }, result.context.pos)
end

T["sia.tools.replace_region"]["fails on invalid line range"] = function()
  local code = [[
    local tool = require("sia.tools.replace_region")
    local utils = require("sia.utils")

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })

    local original = utils.ensure_file_is_loaded
    utils.ensure_file_is_loaded = function(_) return buf end

    local result

    tool.execute({
      target_file = "test.txt",
      start_line = 0,
      end_line = 1,
      text = "X",
    }, { auto_confirm_tools = { replace_region = 1 } }, function(res)
      result = { kind = res.kind, content = res.content, display_content = res.display_content }
    end, nil)

    vim.wait(500, function() return result ~= nil end)

    _G.result = result

    utils.ensure_file_is_loaded = original
  ]]

  child.lua(code)

  local result = child.lua_get("_G.result")
  eq("failed", result.kind)
  eq(true, string.find(result.content[1], "start_line must be >= 1") ~= nil)
end

return T

