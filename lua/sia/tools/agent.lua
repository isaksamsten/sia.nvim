local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons
local tool_names = tool_utils.tool_names

local START_REPLY = [[
Persistent agent launched successfully.
agentId: %d (This is an internal ID for your use, do not mention it to the user.)
The agent is currently working in the background. If you have other tasks you should
continue working on them now.

When you need to interact with this agent again:
- Call agent(command="status", id=id) to check progress or inspect the current state
- Call agent(command="wait", id=id) to wait for the next unread reply
- After the agent replies, call agent(command="send", id=id, message="...") to send a
  follow-up message and continue the same session

Do not call "wait" unless you have nothing else to do, as it will idle until the
agent replies or yields for user input.
If the user sends a message while you are waiting, the wait may yield early with a
status update. You will then see the user's message in the conversation and should
respond before calling wait or status again.
]]

--- @param agent sia.agents.Agent
--- @return string
local function waiting_yield_message(agent)
  return string.format(
    "Agent %d (%s) is still running. Yielding to process user input.\n\n%s",
    agent.id,
    agent.name,
    agent:get_preview()
  )
end

--- @param agent sia.agents.Agent
--- @param callback fun(result:sia.ToolResult)
local function return_pending_result(agent, callback)
  local content = {
    string.format("Agent %d (%s) replied:", agent.id, agent.name),
    "",
  }
  local assistant_content = agent.conversation:get_last_assistant_content()
  if assistant_content and assistant_content ~= "" then
    table.insert(content, assistant_content)
  else
    table.insert(content, "(no assistant message)")
  end
  agent.status = "idle"
  callback({
    content = table.concat(content, "\n"),
    summary = string.format("%s Agent %s replied", icons.agents, agent.name),
  })
end

--- @param agent sia.agents.Agent
local function is_settled(agent)
  return agent.status == "pending"
    or agent.status == "failed"
    or agent.status == "cancelled"
end

--- @param agent sia.agents.Agent
local function is_running(agent)
  return agent.source == "tool" and agent.status == "running"
end

--- @param agent sia.agents.Agent
--- @param callback fun(result:sia.ToolResult)
local function return_settled(agent, callback)
  if agent.status == "pending" then
    return_pending_result(agent, callback)
  elseif agent.status == "failed" then
    callback({
      content = string.format(
        "Agent %d (%s) failed:\nError: %s",
        agent.id,
        agent.name,
        agent.error or "Unknown error"
      ),
      summary = string.format("%s Agent %d failed", icons.error, agent.id),
    })
  elseif agent.status == "cancelled" then
    callback({
      content = string.format(
        "Agent %d (%s) was cancelled by the user.",
        agent.id,
        agent.name
      ),
      summary = string.format("%s Agent %d cancelled", icons.error, agent.id),
    })
  end
end

--- @param id integer
--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
local function wait_for_agent(id, conversation, callback)
  local agent = conversation.agent_runtime:get(id)
  if not agent then
    callback({
      content = string.format(
        "Error: Agent with ID %d not found in this conversation",
        id
      ),
    })
    return
  end

  if is_settled(agent) then
    return_settled(agent, callback)
    return
  end

  local function poll()
    local current = conversation.agent_runtime:get(id)
    if not current then
      callback({ content = "Error: Agent instance was removed" })
      return
    end

    if is_settled(current) then
      return_settled(current, callback)
    elseif conversation:has_pending_user_messages() then
      callback({ content = waiting_yield_message(current) })
    elseif current.view == "open" then
      vim.defer_fn(poll, 1000)
    else
      vim.defer_fn(poll, 500)
    end
  end

  poll()
end

--- @param conversation sia.Conversation
--- @param callback fun(result:sia.ToolResult)
local function wait_for_any(conversation, callback)
  local runtime = conversation.agent_runtime

  if not runtime:any(is_running) then
    local settled = runtime:find(is_settled)
    if settled then
      return_settled(settled, callback)
    else
      callback({
        content = "No agents are running or have pending results.",
        ephemeral = true,
      })
    end
    return
  end

  local function poll()
    local settled = runtime:find(is_settled)
    if settled then
      return_settled(settled, callback)
    elseif conversation:has_pending_user_messages() then
      callback({
        content = "Agents are still running. Yielding to process user input.",
      })
    elseif runtime:any(is_running) then
      vim.defer_fn(poll, 500)
    else
      callback({
        content = "All agents finished but none produced results.",
        ephemeral = true,
      })
    end
  end

  poll()
end

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = "agent",
    description = [[Manage persistent agent sessions for complex, multi-step subtasks.]],
    parameters = {
      command = {
        type = "string",
        enum = { "start", "send", "status", "wait" },
        description = "The command to execute: start a new agent, send a follow-up message, check status, or wait for the next reply",
      },
      agent = {
        type = "string",
        description = "The name of the agent type to launch (required for 'start' command)",
      },
      id = {
        type = "integer",
        description = "The ID of an existing agent session (required for 'send' and 'status'). Optional for 'wait': when omitted, waits for the first agent to finish.",
      },
      message = {
        type = "string",
        description = "A follow-up message to send to an existing agent session (required for 'start' and 'send')",
      },
      cwd = {
        type = "string",
        description = "Optional working directory for the agent (only for 'start'). Omit unless the agent needs to operate in a different directory than the current session's workspace.",
      },
    },
    required = { "command" },
  },
  summary = function(args)
    if args.command == "list" then
      return icons.agents .. " Listing agents"
    elseif args.command == "start" then
      return string.format(
        icons.agents .. " Starting agent '%s'",
        args.agent or "unknown"
      )
    elseif args.command == "send" then
      return string.format(icons.agents .. " Messaging agent '%s'", tostring(args.id))
    elseif args.command == "wait" then
      if args.id then
        return string.format(
          icons.agents .. " Waiting for agent '%s'",
          tostring(args.id)
        )
      else
        return icons.agents .. " Waiting for agents"
      end
    elseif args.command == "status" then
      return string.format(icons.agents .. " Checking agent '%s'", tostring(args.id))
    end
  end,
  read_only = true,
  instructions = string.format(
    [[The agent tool manages persistent agent sessions. Each agent type has specific
capabilities and tools available to it.

Commands:
- `agent(command="start", agent="name", message="...")` starts a new session
- `agent(command="send", id=1, message="...")` sends a follow-up message to an existing session
- `agent(command="status", id=1)` checks the current status and preview
- `agent(command="wait", id=1)` waits for a specific agent's next unread reply
- `agent(command="wait")` waits for the first agent to finish (any agent)

When NOT to use the agent tool:
- If you want to read a specific file path, use the %s or grep tool instead
- If you are searching for a specific class definition like "class Foo", use the grep tool instead
- If you are searching within a specific file or a very small file set, use the %s tool instead
- Other tasks that do not match a specialized agent]],
    tool_names.view,
    tool_names.view
  ),
}, function(args, conversation, callback, opts)
  local registry = require("sia.agent.registry")
  if args.command == "start" then
    if not args.agent then
      callback({
        content = "Error: 'agent' parameter is required for 'start' command",
        ephemeral = true,
      })
      return
    end

    if not args.message then
      callback({
        content = "Error: 'message' parameter is required for 'start' command",
        ephemeral = true,
      })
      return
    end

    local agent_def = registry.get_agent(args.agent)

    if not agent_def then
      callback({
        content = string.format("Error: Agent '%s' not found.", args.agent),
        ephemeral = true,
      })
      return
    end

    local confirm_message =
      string.format("Launch %s agent with message: %s", args.agent, args.message)
    opts.user_input(confirm_message, {
      on_accept = function()
        local agent = conversation.agent_runtime:spawn(args.agent, args.message, {
          workspace = args.cwd,
          source = "tool",
        })

        if not agent then
          callback({
            content = string.format("Agent %s not found", args.agent),
            ephemeral = true,
          })
          return
        end

        callback({
          content = string.format(START_REPLY, agent.id),
          summary = string.format("%s Started agent '%s'", icons.agents, args.agent),
        })
      end,
    })
  elseif args.command == "send" then
    if not args.id then
      callback({
        content = "Error: 'id' parameter is required for 'send' command",
        summary = icons.error .. " Missing id parameter",
      })
      return
    end

    if not args.message then
      callback({
        content = "Error: 'message' parameter is required for 'send' command",
        summary = icons.error .. " Missing message parameter",
      })
      return
    end

    local agent = conversation.agent_runtime:get(args.id)
    if not agent then
      callback({
        content = string.format(
          "Error: Agent with ID %d not found in this conversation",
          args.id
        ),
      })
      return
    end
    if agent.status == "failed" then
      callback({
        content = string.format(
          "Agent %d (%s) has failed and cannot accept new messages",
          agent.id,
          agent.name
        ),
      })
      return
    end
    if agent.status == "pending" then
      callback({
        content = string.format(
          "Agent %d (%s) already has a reply waiting. Call wait before sending more input.",
          agent.id,
          agent.name
        ),
      })
      return
    end

    local was_running = agent.status == "running"
    local confirm_message = string.format(
      "Send follow-up to %s agent #%d: %s",
      agent.name,
      agent.id,
      args.message
    )

    opts.user_input(confirm_message, {
      on_accept = function()
        conversation.agent_runtime:submit(args.id, args.message)
        local content
        if was_running then
          content = string.format(
            "Queued message for running agent %d (%s). Call status to inspect progress or wait for the next reply.",
            agent.id,
            agent.name
          )
        else
          content = string.format(
            "Sent message to agent %d (%s). Call status to inspect progress or wait for the next reply.",
            agent.id,
            agent.name
          )
        end

        callback({
          content = content,
          summary = string.format("%s Updated agent %s", icons.started, agent.name),
        })
      end,
    })
  elseif args.command == "status" then
    if not args.id then
      callback({
        content = "Error: 'id' parameter is required for 'status' command",
        summary = icons.error .. " Missing id parameter",
      })
      return
    end

    local agent = conversation.agent_runtime:get(args.id)

    if not agent then
      callback({
        content = string.format(
          "Error: Agent with ID %d not found in this conversation",
          args.id
        ),
      })
      return
    end

    callback({ content = agent:get_preview() })
  elseif args.command == "wait" then
    if args.id then
      wait_for_agent(args.id, conversation, callback)
    else
      wait_for_any(conversation, callback)
    end
  else
    callback({
      content = string.format("Error: Unknown command '%s'", args.command),
      ephemeral = true,
    })
  end
end)
