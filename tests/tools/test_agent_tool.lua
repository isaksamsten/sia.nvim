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

T["sia.tools.agent"]["list shows configured agents and their tools"] = function()
  child.lua([[
    package.loaded["sia.agent.registry"] = {
      get_agents = function()
        return {
          ["code/review"] = {
            description = "Review changes",
            tools = { "grep", "view" },
            interactive = false,
          },
          ["docs/writer"] = {
            description = "Draft docs",
            tools = { "view", "write" },
            interactive = true,
          },
        }
      end,
    }

    local agent_tool = require("sia.tools.agent")
    local result = nil

    agent_tool.implementation.execute({
      command = "list",
    }, function(res)
      result = res
    end, {
      conversation = {
        auto_confirm_tools = {},
        ignore_tool_confirm = true,
      },
    })

    _G.result = result
  ]])

  local result = child.lua_get("_G.result")

  eq(true, result.content:find("Available agents:", 1, true) ~= nil)
  eq(true, result.content:find("- code/review: Review changes", 1, true) ~= nil)
  eq(true, result.content:find("tools: grep, view", 1, true) ~= nil)
  eq(true, result.content:find("- docs/writer: Draft docs", 1, true) ~= nil)
  eq(true, result.content:find("mode: interactive chat", 1, true) ~= nil)
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
      "Agent 1 %(code/review%) is still running%. Yielding to process user input%.",
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
      latest_message = "Inspect files",
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
        get_agent = function(_, id)
          return id == 2 and current_agent or nil
        end,
        submit_agent = function(_, id, message)
          submitted = { id = id, message = message }
          current_agent.status = "running"
          current_agent.latest_message = message
          return current_agent
        end,
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
      current_agent.status = "pending"
      current_agent.result = { "Review complete" }
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

return T
