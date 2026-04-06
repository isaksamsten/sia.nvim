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

T["sia.tools.agent"] = MiniTest.new_set()

T["sia.tools.agent"]["wait yields early when user has pending input"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local current_agent = {
      id = 1,
      name = "code/review",
      status = "running",
      get_preview = function()
        return table.concat({
          "Agent ID: 1",
          "Agent: code/review",
          "Status: running",
          "Task: Inspect files",
          "Progress: Analyzing",
        }, "\n")
      end,
    }

    local result = nil
    agent_tool.implementation.execute({
      command = "wait",
      id = 1,
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        get_agent = function(_, id)
          return id == 1 and current_agent or nil
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
    _G.instructions = agent_tool.implementation.instructions
  ]])

  local result = child.lua_get("_G.result")
  local instructions = child.lua_get("_G.instructions")

  eq(
    true,
    result.content:find(
      "Agent 1 %(code/review%) is still running%. Yielding to process user input%." ,
      1
    ) ~= nil
  )
  eq(true, result.content:find("Progress: Analyzing", 1, true) ~= nil)
  eq(
    true,
    instructions:find("If the user sends a message while you are waiting", 1, true)
      ~= nil
  )
end

T["sia.tools.agent"]["wait preserves blocking behavior without user input"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local current_agent = {
      id = 1,
      name = "code/review",
      status = "running",
      result = nil,
      get_preview = function()
        return "Agent ID: 1"
      end,
    }

    local result = nil
    agent_tool.implementation.execute({
      command = "wait",
      id = 1,
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        get_agent = function(_, id)
          return id == 1 and current_agent or nil
        end,
        has_pending_user_messages = function()
          return false
        end,
      },
    })

    vim.defer_fn(function()
      current_agent.status = "completed"
      current_agent.result = { "Review complete" }
    end, 50)

    vim.wait(1500, function()
      return result ~= nil
    end)

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.content:find("Agent 1 %(code/review%) completed:", 1) ~= nil)
  eq(true, result.content:find("Review complete", 1, true) ~= nil)
end

return T
