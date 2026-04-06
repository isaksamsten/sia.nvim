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

T["sia.tools.bash"] = MiniTest.new_set()

T["sia.tools.bash"]["start yields early when sync command sees pending input"] = function()
  child.lua([[
    local bash_tool = require("sia.tools.bash")

    local processes = {}
    local next_id = 1
    local result = nil

    local conversation = {
      id = 42,
      auto_confirm_tools = {},
      ignore_tool_confirm = true,
      shell = {
        pwd = function()
          return vim.fn.getcwd()
        end,
        exec = function(_, _, _, _, on_complete)
          vim.defer_fn(function()
            local proc = processes[1]
            proc.status = "completed"
            proc.code = 0
            proc.interrupted = false
            proc.completed_at = vim.uv.hrtime() / 1e9
            on_complete({
              stdout = "done",
              stderr = "",
              code = 0,
              interrupted = false,
            })
          end, 100)
        end,
      },
      new_bash_process = function(_, command, description)
        local proc = {
          id = next_id,
          command = command,
          description = description,
          status = "running",
          started_at = vim.uv.hrtime() / 1e9,
          get_preview = function(self)
            return table.concat({
              "Process ID: " .. self.id,
              "Command: " .. self.command,
              "Status: " .. self.status,
              "stdout (last 1 lines):",
              "building",
            }, "\n")
          end,
        }
        processes[proc.id] = proc
        next_id = next_id + 1
        return proc
      end,
      get_bash_process = function(_, id)
        return processes[id]
      end,
      has_pending_user_messages = function()
        return true
      end,
    }

    bash_tool.implementation.execute({
      command = "start",
      bash_command = "make test",
      description = "Run tests",
    }, function(res)
      result = res
    end, {
      conversation = conversation,
    })

    vim.wait(1000, function()
      return result ~= nil
    end)

    _G.result = result
    _G.instructions = bash_tool.implementation.instructions
  ]])

  local result = child.lua_get("_G.result")
  local instructions = child.lua_get("_G.instructions")

  eq(
    true,
    result.content:find(
      "Process 1 is still running%. Yielding to process user input%.",
      1
    ) ~= nil
  )
  eq(true, result.content:find("building", 1, true) ~= nil)
  eq(
    true,
    instructions:find("blocking `bash%(command=\"start\", async=false%)`", 1) ~= nil
  )
end

T["sia.tools.bash"]["wait yields early when user has pending input"] = function()
  child.lua([[
    local bash_tool = require("sia.tools.bash")

    local current_proc = {
      id = 1,
      command = "make test",
      description = "Run tests",
      status = "running",
      started_at = (vim.uv.hrtime() / 1e9) - 2,
      get_preview = function()
        return table.concat({
          "Process ID: 1",
          "Command: make test",
          "Status: running",
          "stdout (last 1 lines):",
          "still running",
        }, "\n")
      end,
    }

    local result = nil
    bash_tool.implementation.execute({
      command = "wait",
      id = 1,
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        get_bash_process = function(_, id)
          return id == 1 and current_proc or nil
        end,
        has_pending_user_messages = function()
          return true
        end,
      },
    })

    vim.wait(1000, function()
      return result ~= nil
    end)

    _G.result = result
    _G.instructions = bash_tool.implementation.instructions
  ]])

  local result = child.lua_get("_G.result")
  local instructions = child.lua_get("_G.instructions")

  eq(
    true,
    result.content:find(
      "Process 1 is still running%. Yielding to process user input%.",
      1
    ) ~= nil
  )
  eq(true, result.content:find("still running", 1, true) ~= nil)
  eq(
    true,
    instructions:find("If the user sends a message while you are waiting", 1, true)
      ~= nil
  )
end

T["sia.tools.bash"]["start preserves blocking behavior without user input"] = function()
  child.lua([[
    local bash_tool = require("sia.tools.bash")

    local processes = {}
    local next_id = 1
    local result = nil

    local conversation = {
      id = 43,
      auto_confirm_tools = {},
      ignore_tool_confirm = true,
      shell = {
        pwd = function()
          return vim.fn.getcwd()
        end,
        exec = function(_, _, _, _, on_complete)
          vim.defer_fn(function()
            local proc = processes[1]
            proc.status = "completed"
            proc.code = 0
            proc.interrupted = false
            proc.completed_at = vim.uv.hrtime() / 1e9
            on_complete({
              stdout = "all good",
              stderr = "",
              code = 0,
              interrupted = false,
            })
          end, 50)
        end,
      },
      new_bash_process = function(_, command, description)
        local proc = {
          id = next_id,
          command = command,
          description = description,
          status = "running",
          started_at = vim.uv.hrtime() / 1e9,
          get_preview = function()
            return "Process ID: 1"
          end,
        }
        processes[proc.id] = proc
        next_id = next_id + 1
        return proc
      end,
      get_bash_process = function(_, id)
        return processes[id]
      end,
      has_pending_user_messages = function()
        return false
      end,
    }

    bash_tool.implementation.execute({
      command = "start",
      bash_command = "make test",
      description = "Run tests",
    }, function(res)
      result = res
    end, {
      conversation = conversation,
    })

    vim.wait(1500, function()
      return result ~= nil
    end)

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.content:find("Process 1 completed%.", 1) ~= nil)
  eq(true, result.content:find("stdout:", 1, true) ~= nil)
  eq(true, result.content:find("all good", 1, true) ~= nil)
end

T["sia.tools.bash"]["wait preserves blocking behavior without user input"] = function()
  child.lua([[
    local bash_tool = require("sia.tools.bash")

    local current_proc = {
      id = 1,
      command = "make test",
      description = "Run tests",
      status = "running",
      started_at = vim.uv.hrtime() / 1e9,
      get_preview = function()
        return "Process ID: 1"
      end,
    }

    local result = nil
    bash_tool.implementation.execute({
      command = "wait",
      id = 1,
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        shell = {
          pwd = function()
            return vim.fn.getcwd()
          end,
        },
        get_bash_process = function(_, id)
          return id == 1 and current_proc or nil
        end,
        has_pending_user_messages = function()
          return false
        end,
      },
    })

    vim.defer_fn(function()
      current_proc.status = "completed"
      current_proc.code = 0
      current_proc.interrupted = false
      current_proc.completed_at = vim.uv.hrtime() / 1e9
    end, 50)

    vim.wait(1500, function()
      return result ~= nil
    end)

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.content:find("Process 1 completed%.", 1) ~= nil)
  eq(true, result.content:find("Command completed successfully", 1, true) ~= nil)
end

return T
