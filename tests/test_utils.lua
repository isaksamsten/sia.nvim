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

T["sia.utils.CommandParser"] = MiniTest.new_set()

T["sia.utils.CommandParser"]["parses multiple flags before action and mode"] = function()
  local code = [[
    local parser = require("sia.utils").CommandParser.new({ flags = { "m", "s" } })
    _G.parsed = parser:parse({
      "-m",
      "openai/gpt-4.1",
      "-s",
      "update-docs",
      "/doc",
      "@plan",
      "refresh",
      "docs",
    })
  ]]

  child.lua(code)

  local parsed = child.lua_get("_G.parsed")
  eq("openai/gpt-4.1", parsed.flags.m)
  eq("update-docs", parsed.flags.s)
  eq("doc", parsed.action)
  eq("plan", parsed.mode)
  eq({ "refresh", "docs" }, parsed.positional)
end

T["sia.utils.ensure_file_is_loaded"] = MiniTest.new_set()

-- Regression test: ensure_file_is_loaded("task2.py") must NOT return the
-- buffer for "my/dir/task2.py" just because the basenames match.
T["sia.utils.ensure_file_is_loaded"]["does not confuse same-basename files in different directories"] = function()
  local code = [[
    local utils = require("sia.utils")

    -- Create two temp directories with files sharing the same basename.
    local dir1 = vim.fn.tempname()
    local dir2 = vim.fn.tempname()
    vim.fn.mkdir(dir1, "p")
    vim.fn.mkdir(dir2, "p")

    local file_in_dir1 = dir1 .. "/task2.py"
    local file_in_dir2 = dir2 .. "/task2.py"

    vim.fn.writefile({ "# dir1" }, file_in_dir1)
    vim.fn.writefile({ "# dir2" }, file_in_dir2)

    -- Load the file from dir1 first so it is in the buffer list.
    local buf1 = utils.ensure_file_is_loaded(file_in_dir1)

    -- Now ask for the file from dir2 – must get a *different* buffer.
    local buf2 = utils.ensure_file_is_loaded(file_in_dir2)

    _G.buf1 = buf1
    _G.buf2 = buf2
    _G.buf1_name = buf1 and vim.fn.resolve(vim.api.nvim_buf_get_name(buf1)) or nil
    _G.buf2_name = buf2 and vim.fn.resolve(vim.api.nvim_buf_get_name(buf2)) or nil
    _G.file_in_dir1 = vim.fn.resolve(file_in_dir1)
    _G.file_in_dir2 = vim.fn.resolve(file_in_dir2)

    -- Cleanup
    vim.fn.delete(dir1, "rf")
    vim.fn.delete(dir2, "rf")
  ]]

  child.lua(code)

  local buf1 = child.lua_get("_G.buf1")
  local buf2 = child.lua_get("_G.buf2")
  local buf1_name = child.lua_get("_G.buf1_name")
  local buf2_name = child.lua_get("_G.buf2_name")
  local file_in_dir1 = child.lua_get("_G.file_in_dir1")
  local file_in_dir2 = child.lua_get("_G.file_in_dir2")

  -- Both buffers must be valid (non-nil).
  eq(true, buf1 ~= nil)
  eq(true, buf2 ~= nil)

  -- They must be distinct buffers.
  eq(true, buf1 ~= buf2)

  -- Each buffer must point to its own file, not the other's.
  eq(file_in_dir1, buf1_name)
  eq(file_in_dir2, buf2_name)
end

-- Sanity check: loading the same absolute path twice returns the same buffer.
T["sia.utils.ensure_file_is_loaded"]["returns same buffer for same absolute path"] = function()
  local code = [[
    local utils = require("sia.utils")

    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = dir .. "/same.py"
    vim.fn.writefile({ "x = 1" }, file)

    local buf1 = utils.ensure_file_is_loaded(file)
    local buf2 = utils.ensure_file_is_loaded(file)

    _G.buf1 = buf1
    _G.buf2 = buf2

    vim.fn.delete(dir, "rf")
  ]]

  child.lua(code)

  local buf1 = child.lua_get("_G.buf1")
  local buf2 = child.lua_get("_G.buf2")

  eq(true, buf1 ~= nil)
  eq(buf1, buf2)
end

-- Ensure a relative path resolves against cwd and does NOT steal the buffer
-- of a deeper file with the same basename.
T["sia.utils.ensure_file_is_loaded"]["relative path resolves against cwd not a deeper loaded file"] = function()
  local code = [[
    local utils = require("sia.utils")

    -- Simulate the scenario: agent has "my/dir/task2.py" already loaded,
    -- then asks for "task2.py" (meaning <cwd>/task2.py).
    local cwd = vim.fn.getcwd()

    local deep_dir = vim.fn.tempname()
    vim.fn.mkdir(deep_dir, "p")
    local deep_file = deep_dir .. "/task2.py"
    vim.fn.writefile({ "# deep" }, deep_file)

    -- Load the deep file first.
    local deep_buf = utils.ensure_file_is_loaded(deep_file)

    -- Create a real file at <cwd>/task2.py so ensure_file_is_loaded can load it.
    local root_file = cwd .. "/task2.py"
    vim.fn.writefile({ "# root" }, root_file)

    -- Ask for the bare filename – must resolve to cwd/task2.py.
    local root_buf = utils.ensure_file_is_loaded(root_file)

    _G.deep_buf  = deep_buf
    _G.root_buf  = root_buf
    _G.deep_name = deep_buf and vim.fn.resolve(vim.api.nvim_buf_get_name(deep_buf)) or nil
    _G.root_name = root_buf and vim.fn.resolve(vim.api.nvim_buf_get_name(root_buf)) or nil
    _G.deep_file = vim.fn.resolve(deep_file)
    _G.root_file = vim.fn.resolve(root_file)

    -- Cleanup
    vim.fn.delete(deep_dir, "rf")
    vim.fn.delete(root_file)
  ]]

  child.lua(code)

  local deep_buf = child.lua_get("_G.deep_buf")
  local root_buf = child.lua_get("_G.root_buf")
  local deep_name = child.lua_get("_G.deep_name")
  local root_name = child.lua_get("_G.root_name")
  local deep_file = child.lua_get("_G.deep_file")
  local root_file = child.lua_get("_G.root_file")

  eq(true, deep_buf ~= nil)
  eq(true, root_buf ~= nil)
  eq(true, deep_buf ~= root_buf)
  eq(deep_file, deep_name)
  eq(root_file, root_name)
end

return T
