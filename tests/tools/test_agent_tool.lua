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

T["sia.tools.agent"]["start errors when agent parameter missing"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local result = nil
    agent_tool.implementation.execute({
      command = "start",
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        agent_runtime = {
          get = function() return nil end,
        },
      },
    })

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  eq(true, result.content:find("Error: 'agent' parameter is required", 1, true) ~= nil)
end

T["sia.tools.agent"]["status returns agent preview"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local mock_agent = {
      id = 1,
      name = "code/review",
      status = "running",
      get_preview = function(self)
        return table.concat({
          "Agent ID: " .. self.id,
          "Agent: " .. self.name,
          "Status: " .. self.status,
          "Task: Inspect files",
        }, "\n")
      end,
    }

    local result = nil
    agent_tool.implementation.execute({
      command = "status",
      id = 1,
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        agent_runtime = {
          get = function(_, id)
            return id == 1 and mock_agent or nil
          end,
        },
      },
    })

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  eq(true, result.content:find("Agent ID: 1", 1, true) ~= nil)
  eq(true, result.content:find("Agent: code/review", 1, true) ~= nil)
  eq(true, result.content:find("Status: running", 1, true) ~= nil)
end

T["sia.tools.agent"]["status errors on missing id"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local result = nil
    agent_tool.implementation.execute({
      command = "status",
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        agent_runtime = {
          get = function() return nil end,
        },
      },
    })

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  eq(true, result.content:find("Error: 'id' parameter is required", 1, true) ~= nil)
end

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
        agent_runtime = {
          get = function(_, id)
            return id == 1 and current_agent or nil
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
    _G.instructions = agent_tool.implementation.instructions
  ]])

  local result = child.lua_get("_G.result")
  local instructions = child.lua_get("_G.instructions")

  eq(
    true,
    result.content:find(
      "Agent 1 %(code/review%) is still running%. Yielding to process user input%.",
      1
    ) ~= nil
  )
  eq(true, result.content:find("Progress: Analyzing", 1, true) ~= nil)
  eq(
    true,
    instructions:find('agent%(command="wait", id=1%)', 1) ~= nil
  )
end

T["sia.tools.agent"]["send forwards follow-up messages to an existing session"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local submitted = nil
    local result = nil
    local current_agent = {
      id = 2,
      name = "code/review",
      status = "idle",
      view = "closed",
      task = "Inspect files",
    }

    agent_tool.implementation.execute({
      command = "send",
      id = 2,
      message = "Focus on tests next",
    }, function(res)
      result = res
    end, {
      user_input = function(_prompt, confirm_opts)
        confirm_opts.on_accept()
      end,
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        agent_runtime = {
          get = function(_, id)
            return id == 2 and current_agent or nil
          end,
          submit = function(_, id, message)
            submitted = { id = id, message = message }
            current_agent.status = "running"
          end,
        },
      },
    })

    _G.result = result
    _G.submitted = submitted
    _G.instructions = agent_tool.implementation.instructions
  ]])

  local result = child.lua_get("_G.result")
  local submitted = child.lua_get("_G.submitted")
  local instructions = child.lua_get("_G.instructions")

  eq(2, submitted.id)
  eq("Focus on tests next", submitted.message)
  eq(true, result.content:find("Sent message to agent 2 %(code/review%)", 1) ~= nil)
  eq(
    true,
    instructions:find('agent%(command="send", id=1, message="%.%.%.%"%)', 1) ~= nil
  )
  eq(false, instructions:find("stateless", 1, true) ~= nil)
end

T["sia.tools.agent"]["wait preserves blocking behavior without user input"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local current_agent = {
      id = 1,
      name = "code/review",
      status = "running",
      conversation = {
        get_last_assistant_content = function()
          return "Review complete"
        end,
      },
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
        agent_runtime = {
          get = function(_, id)
            return id == 1 and current_agent or nil
          end,
        },
        has_pending_user_messages = function()
          return false
        end,
      },
    })

    vim.defer_fn(function()
      current_agent.status = "pending"
    end, 50)

    vim.wait(1500, function()
      return result ~= nil
    end)

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.content:find("Agent 1 %(code/review%) replied:", 1) ~= nil)
  eq(true, result.content:find("Review complete", 1, true) ~= nil)
end

T["sia.tools.agent"]["wait returns failed agent error"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local current_agent = {
      id = 3,
      name = "searcher",
      status = "failed",
      error = "API timeout",
    }

    local result = nil
    agent_tool.implementation.execute({
      command = "wait",
      id = 3,
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        agent_runtime = {
          get = function(_, id)
            return id == 3 and current_agent or nil
          end,
        },
      },
    })

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  eq(true, result.content:find("failed", 1, true) ~= nil)
  eq(true, result.content:find("API timeout", 1, true) ~= nil)
end

T["sia.tools.agent"]["wait returns cancelled agent message"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local current_agent = {
      id = 4,
      name = "writer",
      status = "cancelled",
    }

    local result = nil
    agent_tool.implementation.execute({
      command = "wait",
      id = 4,
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        agent_runtime = {
          get = function(_, id)
            return id == 4 and current_agent or nil
          end,
        },
      },
    })

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  eq(true, result.content:find("cancelled", 1, true) ~= nil)
end

T["sia.tools.agent"]["send rejects message to failed agent"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local current_agent = {
      id = 5,
      name = "broken",
      status = "failed",
      error = "crashed",
    }

    local result = nil
    agent_tool.implementation.execute({
      command = "send",
      id = 5,
      message = "try again",
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        agent_runtime = {
          get = function(_, id)
            return id == 5 and current_agent or nil
          end,
        },
      },
    })

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  eq(true, result.content:find("failed", 1, true) ~= nil)
end

T["sia.tools.agent"]["unknown command returns error"] = function()
  child.lua([[
    local agent_tool = require("sia.tools.agent")

    local result = nil
    agent_tool.implementation.execute({
      command = "invalid_command",
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
        agent_runtime = {},
      },
    })

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")
  eq(true, result.content:find("Unknown command", 1, true) ~= nil)
end

return T

