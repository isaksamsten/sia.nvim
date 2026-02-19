local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.shell"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      T.child = MiniTest.new_child_neovim()
      T.child.restart({ "-u", "assets/minimal.lua" })
    end,
    post_once = function()
      T.child.stop()
    end,
  },
})

T["sia.shell"]["spawn_detached runs command and returns result"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false

    shell:spawn_detached("echo hello world", nil, nil, function(result)
      _G.result = result
      completed = true
    end)

    vim.wait(5000, function() return completed end, 10)
    _G.completed = completed
    shell:close()
  ]])

  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(0, result.code)
  eq(false, result.interrupted)
  eq("hello world\n", result.stdout)
  eq("", result.stderr)
end

T["sia.shell"]["spawn_detached captures stderr"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false

    shell:spawn_detached("echo err >&2; exit 1", nil, nil, function(result)
      _G.result = result
      completed = true
    end)

    vim.wait(5000, function() return completed end, 10)
    _G.completed = completed
    shell:close()
  ]])

  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(1, result.code)
  eq("err\n", result.stderr)
end

T["sia.shell"]["spawn_detached does not block main shell queue"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local detached_done = false
    local sync_done = false
    local sync_finished_first = false

    -- Launch a slow detached command
    shell:spawn_detached("sleep 2 && echo slow", nil, nil, function(result)
      _G.detached_result = result
      detached_done = true
    end)

    -- Immediately run a fast sync command through the main queue
    shell:exec("echo fast", nil, nil, function(result)
      _G.sync_result = result
      sync_done = true
      -- Record whether sync finished before detached
      sync_finished_first = not detached_done
    end)

    -- Wait for sync to complete (should be fast)
    vim.wait(5000, function() return sync_done end, 10)
    _G.sync_done = sync_done
    _G.sync_finished_first = sync_finished_first

    -- Clean up: kill the slow detached process
    shell:close()
  ]])

  local sync_done = T.child.lua_get("_G.sync_done")
  local sync_finished_first = T.child.lua_get("_G.sync_finished_first")
  local sync_result = T.child.lua_get("_G.sync_result")

  eq(true, sync_done)
  eq(true, sync_finished_first)
  eq(0, sync_result.code)
  -- Sync shell reads from temp files (readfile strips trailing newline)
  eq("fast", sync_result.stdout)
end

T["sia.shell"]["spawn_detached inherits cwd from main shell"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false

    -- Change directory in the main shell
    local sync_done = false
    shell:exec("cd /tmp", nil, nil, function()
      sync_done = true
    end)
    vim.wait(5000, function() return sync_done end, 10)

    -- Spawn detached — should inherit /tmp as cwd
    -- But /tmp is outside project root, so it should fall back to project root
    shell:spawn_detached("pwd", nil, nil, function(result)
      _G.result = result
      completed = true
    end)

    vim.wait(5000, function() return completed end, 10)
    _G.completed = completed
    _G.project_root = vim.fn.getcwd()
    shell:close()
  ]])

  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")
  local project_root = T.child.lua_get("_G.project_root")

  eq(true, completed)
  eq(0, result.code)
  -- Should fall back to project root since /tmp is outside the project
  eq(project_root .. "\n", result.stdout)
end

T["sia.shell"]["spawn_detached inherits cwd within project"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local project_root = vim.fn.getcwd()
    local shell = Shell.new(project_root)
    local completed = false

    -- Change to a subdirectory within the project
    local sync_done = false
    shell:exec("cd lua", nil, nil, function()
      sync_done = true
    end)
    vim.wait(5000, function() return sync_done end, 10)

    -- Spawn detached — should inherit the subdirectory
    shell:spawn_detached("pwd", nil, nil, function(result)
      _G.result = result
      completed = true
    end)

    vim.wait(5000, function() return completed end, 10)
    _G.completed = completed
    _G.expected_cwd = project_root .. "/lua"
    shell:close()
  ]])

  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")
  local expected_cwd = T.child.lua_get("_G.expected_cwd")

  eq(true, completed)
  eq(0, result.code)
  eq(expected_cwd .. "\n", result.stdout)
end

T["sia.shell"]["spawn_detached times out"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false

    -- Use a very short timeout
    shell:spawn_detached("sleep 10", 500, nil, function(result)
      _G.result = result
      completed = true
    end)

    vim.wait(5000, function() return completed end, 10)
    _G.completed = completed
    shell:close()
  ]])

  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(143, result.code)
  eq(true, result.interrupted)
  eq(true, result.stderr:find("timed out") ~= nil)
end

T["sia.shell"]["spawn_detached can be cancelled"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false
    local cancellable = { is_cancelled = false }

    shell:spawn_detached("sleep 10", 30000, cancellable, function(result)
      _G.result = result
      completed = true
    end)

    -- Cancel after a short delay
    vim.defer_fn(function()
      cancellable.is_cancelled = true
    end, 200)

    vim.wait(5000, function() return completed end, 10)
    _G.completed = completed
    shell:close()
  ]])

  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(true, result.interrupted)
end

T["sia.shell"]["spawn_detached does not inherit shell exports"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false

    -- Set an export in the main shell
    local sync_done = false
    shell:exec("export SIA_TEST_VAR=secret123", nil, nil, function()
      sync_done = true
    end)
    vim.wait(5000, function() return sync_done end, 10)

    -- Spawn detached — should NOT see the export
    shell:spawn_detached('echo "VAR=$SIA_TEST_VAR"', nil, nil, function(result)
      _G.result = result
      completed = true
    end)

    vim.wait(5000, function() return completed end, 10)
    _G.completed = completed
    shell:close()
  ]])

  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(0, result.code)
  -- The variable should be empty since detached doesn't inherit shell state
  eq("VAR=\n", result.stdout)
end

T["sia.shell"]["spawn_detached kill stops the process"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false

    local handle = shell:spawn_detached("sleep 30", 60000, nil, function(result)
      _G.result = result
      completed = true
    end)

    -- Kill immediately
    vim.defer_fn(function()
      handle.kill()
    end, 100)

    vim.wait(5000, function() return completed end, 10)
    _G.completed = completed
    _G.is_done = handle.is_done()
    shell:close()
  ]])

  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")
  local is_done = T.child.lua_get("_G.is_done")

  eq(true, completed)
  eq(true, is_done)
  eq(true, result.interrupted)
end

T["sia.shell"]["multiple spawn_detached run concurrently"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local results = {}
    local count = 0

    for i = 1, 3 do
      shell:spawn_detached("echo proc" .. i, nil, nil, function(result)
        results[i] = result
        count = count + 1
      end)
    end

    vim.wait(5000, function() return count == 3 end, 10)
    _G.count = count
    _G.results = results
    shell:close()
  ]])

  local count = T.child.lua_get("_G.count")
  local results = T.child.lua_get("_G.results")

  eq(3, count)
  for i = 1, 3 do
    eq(0, results[i].code)
    eq("proc" .. i .. "\n", results[i].stdout)
  end
end

T["sia.shell"]["spawn_detached strips ansi codes"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false

    shell:spawn_detached('printf "\\033[31mred\\033[0m text"', nil, nil, function(result)
      _G.result = result
      completed = true
    end)

    vim.wait(5000, function() return completed end, 10)
    _G.completed = completed
    shell:close()
  ]])

  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")

  eq(true, completed)
  eq("red text", result.stdout)
end

T["sia.shell"]["spawn_detached get_output returns partial output while running"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false

    -- Command that produces output over time
    local handle = shell:spawn_detached(
      'for i in 1 2 3; do echo "line$i"; sleep 0.1; done; sleep 2',
      10000,
      nil,
      function(result)
        _G.final_result = result
        completed = true
      end
    )

    -- Wait a bit for some output to be produced
    vim.wait(1000, function() return false end, 50)

    -- Get partial output while still running
    local partial = handle.get_output()
    _G.partial_stdout = partial.stdout
    _G.is_running = not handle.is_done()

    -- Now wait for completion
    vim.wait(5000, function() return completed end, 10)
    _G.completed = completed
    shell:close()
  ]])

  local is_running = T.child.lua_get("_G.is_running")
  local partial_stdout = T.child.lua_get("_G.partial_stdout")
  local completed = T.child.lua_get("_G.completed")
  local final_result = T.child.lua_get("_G.final_result")

  eq(true, is_running)
  -- Should have captured some output while running
  eq(true, partial_stdout:find("line1") ~= nil)
  eq(true, completed)
  eq(true, final_result.stdout:find("line3") ~= nil)
end

T["sia.shell"]["spawn_detached get_output returns empty when no output yet"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false

    local handle = shell:spawn_detached("sleep 2", 5000, nil, function(result)
      completed = true
    end)

    -- Check immediately — no output yet
    local partial = handle.get_output()
    _G.partial_stdout = partial.stdout
    _G.partial_stderr = partial.stderr

    handle.kill()
    vim.wait(5000, function() return completed end, 10)
    shell:close()
  ]])

  local partial_stdout = T.child.lua_get("_G.partial_stdout")
  local partial_stderr = T.child.lua_get("_G.partial_stderr")

  eq("", partial_stdout)
  eq("", partial_stderr)
end

T["sia.shell"]["spawn_detached tail -f sees new data on subsequent get_output"] = function()
  T.child.lua([[
    local Shell = require("sia.shell")
    local shell = Shell.new(vim.fn.getcwd())
    local completed = false

    -- Create a temp file with initial content
    local tmpfile = vim.fn.tempname()
    vim.fn.writefile({"initial line"}, tmpfile)

    local handle = shell:spawn_detached("tail -f " .. tmpfile, nil, nil, function(result)
      _G.final_result = result
      completed = true
    end)

    -- Wait for tail to pick up the initial content
    vim.wait(2000, function()
      local out = handle.get_output()
      return out.stdout:find("initial line") ~= nil
    end, 50)

    local first = handle.get_output()
    _G.first_stdout = first.stdout

    -- Append new data to the file
    vim.fn.writefile({"second line", "third line"}, tmpfile, "a")

    -- Wait for tail to pick up the new data
    vim.wait(2000, function()
      local out = handle.get_output()
      return out.stdout:find("third line") ~= nil
    end, 50)

    local second = handle.get_output()
    _G.second_stdout = second.stdout

    -- Append even more data
    vim.fn.writefile({"fourth line"}, tmpfile, "a")

    vim.wait(2000, function()
      local out = handle.get_output()
      return out.stdout:find("fourth line") ~= nil
    end, 50)

    local third = handle.get_output()
    _G.third_stdout = third.stdout

    -- Clean up
    handle.kill()
    vim.wait(5000, function() return completed end, 10)
    vim.fn.delete(tmpfile)
    shell:close()
  ]])

  local first_stdout = T.child.lua_get("_G.first_stdout")
  local second_stdout = T.child.lua_get("_G.second_stdout")
  local third_stdout = T.child.lua_get("_G.third_stdout")

  -- First read: only initial content
  eq(true, first_stdout:find("initial line") ~= nil)
  eq(nil, first_stdout:find("second line"))

  -- Second read: includes new data
  eq(true, second_stdout:find("initial line") ~= nil)
  eq(true, second_stdout:find("second line") ~= nil)
  eq(true, second_stdout:find("third line") ~= nil)

  -- Third read: includes all data
  eq(true, third_stdout:find("fourth line") ~= nil)
end

return T
