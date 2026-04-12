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
    local result = nil
    local current_proc = nil
    local outputs = {}
    local process_runtime = {
      exec = function(_, command, opts)
        current_proc = {
          id = 1,
          kind = "running",
          command = command,
          description = opts.description,
        }
        outputs[1] = { stdout = "building", stderr = "" }
        vim.defer_fn(function()
          current_proc = {
            id = 1,
            kind = "finished",
            outcome = "completed",
            command = command,
            description = opts.description,
            code = 0,
          }
        end, 100)
        return current_proc
      end,
      get = function(_, id)
        return id == 1 and current_proc or nil
      end,
      get_output = function(_, id)
        return outputs[id] or { stdout = "", stderr = "" }
      end,
      pwd = function()
        return vim.fn.getcwd()
      end,
    }

    local conversation = {
      id = 42,
      approved_tools = setmetatable({}, {__index = function() return true end}),
      
      process_runtime = process_runtime,
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
  eq(
    true,
    result.content:find("building", 1, true) ~= nil
      or result.content:find("running", 1, true) ~= nil
  )
  eq(
    true,
    instructions:find('blocking `bash%(command="start", async=false%)`', 1) ~= nil
  )
end

T["sia.tools.bash"]["wait yields early when user has pending input"] = function()
  child.lua([[
    local bash_tool = require("sia.tools.bash")
    local current_proc = {
      id = 1,
      kind = "running",
      command = "make test",
      description = "Run tests",
    }

    local result = nil
    bash_tool.implementation.execute({
      command = "wait",
      id = 1,
    }, function(res)
      result = res
    end, {
      conversation = {
        id = 42,
        approved_tools = setmetatable({}, {__index = function() return true end}),
        
        process_runtime = {
          get = function(_, id)
            return id == 1 and current_proc or nil
          end,
          get_output = function()
            return { stdout = "still running", stderr = "" }
          end,
        },
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

    local result = nil
    local current_proc = nil
    local outputs = {}
    local process_runtime = {
      exec = function(_, command, opts)
        current_proc = {
          id = 1,
          kind = "running",
          command = command,
          description = opts.description,
        }
        outputs[1] = { stdout = "", stderr = "" }
        vim.defer_fn(function()
          outputs[1] = { stdout = "all good", stderr = "" }
          current_proc = {
            id = 1,
            kind = "finished",
            outcome = "completed",
            command = command,
            description = opts.description,
            code = 0,
          }
        end, 50)
        return current_proc
      end,
      get = function(_, id)
          return id == 1 and current_proc or nil
        end,
      get_output = function(_, id)
        return outputs[id] or { stdout = "", stderr = "" }
      end,
      pwd = function()
        return vim.fn.getcwd()
      end,
    }

    local conversation = {
      id = 43,
      approved_tools = setmetatable({}, {__index = function() return true end}),
      
      process_runtime = process_runtime,
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
      kind = "running",
      command = "make test",
      description = "Run tests",
    }
    local output = { stdout = "", stderr = "" }

    local result = nil
    bash_tool.implementation.execute({
      command = "wait",
      id = 1,
    }, function(res)
      result = res
    end, {
      conversation = {
        id = 42,
        approved_tools = setmetatable({}, {__index = function() return true end}),
        
        process_runtime = {
          get = function(_, id)
            return id == 1 and current_proc or nil
          end,
          get_output = function()
            return output
          end,
          pwd = function()
            return vim.fn.getcwd()
          end,
        },
        has_pending_user_messages = function()
          return false
        end,
      },
    })

    vim.defer_fn(function()
      current_proc = {
        id = 1,
        kind = "finished",
        outcome = "completed",
        command = "make test",
        description = "Run tests",
        code = 0,
      }
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

T["sia.tools.bash"]["status builds preview from runtime output"] = function()
  child.lua([[
    local bash_tool = require("sia.tools.bash")
    local result = nil

    bash_tool.implementation.execute({
      command = "status",
      id = 1,
    }, function(res)
      result = res
    end, {
      conversation = {
        id = 99,
        approved_tools = setmetatable({}, {__index = function() return true end}),
        
        process_runtime = {
          get = function(_, id)
            if id ~= 1 then
              return nil
            end
            return {
              id = 1,
              kind = "running",
              command = "make test",
              description = "Run tests",
            }
          end,
          get_output = function()
            return {
              stdout = "alpha\nbeta",
              stderr = "warn",
            }
          end,
        },
      },
    })

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.content:find("Status: running", 1, true) ~= nil)
  eq(true, result.content:find("beta", 1, true) ~= nil)
  eq(true, result.content:find("warn", 1, true) ~= nil)
end

T["sia.tools.bash"]["view paginates full process output"] = function()
  child.lua([[
    local bash_tool = require("sia.tools.bash")
    local result = nil

    bash_tool.implementation.execute({
      command = "view",
      id = 1,
      offset = 2,
      limit = 2,
      stream="both",
    }, function(res)
      result = res
    end, {
      conversation = {
        id = 99,
        approved_tools = setmetatable({}, {__index = function() return true end}),
        
        process_runtime = {
          get = function(_, id)
            if id ~= 1 then
              return nil
            end
            return {
              id = 1,
              kind = "finished",
              outcome = "completed",
              command = "make test",
              description = "Run tests",
              code = 0,
              file = {stdout="", stderr=""}
            }
          end,
          get_output = function()
            return {
              stdout = "alpha\nbeta\ngamma\ndelta",
              stderr = "warn-1\nwarn-2\nwarn-3",
            }
          end,
        },
      },
    })

    _G.result = result
    _G.instructions = bash_tool.implementation.instructions
  ]])

  local result = child.lua_get("_G.result")
  local instructions = child.lua_get("_G.instructions")

  eq(true, result.content:find("stdout:", 1, true) ~= nil)
  eq(true, result.content:find("lines 2-3 of 4", 1, true) ~= nil)
  eq(true, result.content:find("beta", 1, true) ~= nil)
  eq(true, result.content:find("gamma", 1, true) ~= nil)
  eq(true, result.content:find("Use offset=4 to continue.", 1, true) ~= nil)
  eq(true, result.content:find("stderr:", 1, true) ~= nil)
  eq(true, result.content:find("warn%-2", 1) ~= nil)
  eq(true, result.summary:find("Viewed process 1 output", 1, true) ~= nil)
end

T["sia.tools.bash"]["view requires process id"] = function()
  child.lua([[
    local bash_tool = require("sia.tools.bash")
    local result = nil

    bash_tool.implementation.execute({
      command = "view",
    }, function(res)
      result = res
    end, {
      conversation = {
        id = 99,
        approved_tools = setmetatable({}, {__index = function() return true end}),
        
        process_runtime = {},
      },
    })

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")

  eq("Error: 'id' parameter is required for 'view'", result.content)
end

return T
