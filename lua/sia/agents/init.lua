local M = {}

--- Spawn a registered agent in the background, attached to a parent conversation.
---
--- Creates a new hidden conversation with the agent's configured tools and model,
--- adds the system prompt and user task, then executes it via HiddenStrategy.
--- The agent is tracked on `parent_conversation.agents[]`.
---
--- @class sia.agents.SpawnOpts
--- @field source "tool"|"user"? Source of the spawn (default: "user")
--- @field on_complete (fun(agent: sia.conversation.Agent))? Called when the agent finishes (success or failure)
--- @field on_progress (fun(agent: sia.conversation.Agent, msg: string))? Called on progress updates

--- @param agent_name string
--- @param task string
--- @param parent_conversation sia.Conversation
--- @param opts sia.agents.SpawnOpts?
--- @return sia.conversation.Agent?
function M.spawn(agent_name, task, parent_conversation, opts)
  opts = opts or {}

  local config = require("sia.config")
  local registry = require("sia.agents.registry")

  local agent_def = registry.get_agent(agent_name)
  if not agent_def then
    return nil
  end

  local agent = parent_conversation:new_agent(agent_name, task, opts.source or "user")
  local tools = require("sia.tools")

  local Conversation = require("sia.conversation")
  local new_conversation = Conversation.new_conversation({
    model = require("sia.model").resolve(
      agent_def.model or config.options.settings.fast_model
    ),
    ignore_tool_confirm = agent_def.require_confirmation == false,
    tools = vim
      .iter(agent_def.tools)
      :filter(function(tool)
        return tools[tool] ~= nil
      end)
      :map(function(tool)
        return tools[tool]
      end)
      :totable(),
    temporary = true,
  })

  new_conversation:add_instruction({
    { role = "system", content = agent_def.system_prompt },
    { role = "user", content = task },
  })
  new_conversation.name = parent_conversation.name .. "-" .. agent.name

  agent.meta = {
    current = new_conversation,
    parent = parent_conversation,
  }
  local strategy = require("sia.strategy").new_hidden(nil, new_conversation, {
    notify = function(msg)
      agent.progress = msg
      if opts.on_progress then
        opts.on_progress(agent, msg)
      end
    end,
    callback = function(_, result)
      if agent.status == "cancelled" then
        result.error = "Cancelled by user"
        if opts.on_complete then
          opts.on_complete(agent)
        end
        return
      end

      if
        not result.error
        and not (agent.cancellable and agent.cancellable.is_cancelled)
      then
        agent.result = result.content or { "No response" }
        agent.progress = nil
      else
        agent.status = "failed"
        agent.error = result.error
        agent.progress = nil
        agent.usage = result.usage
        if opts.on_complete then
          opts.on_complete(agent)
        end
        return
      end
      agent.usage = result.usage

      if agent.open then
        vim.schedule(function()
          M._open_agent_chat(agent)
        end)
        return
      end

      agent.status = "completed"
      if opts.on_complete then
        opts.on_complete(agent)
      end
    end,
  }, agent.cancellable)

  require("sia.assistant").execute_strategy(strategy)
  return agent
end

--- Open an agent's conversation as a full interactive chat.
--- @param agent sia.conversation.Agent
function M._open_agent_chat(agent)
  if not agent.open or not agent.meta then
    return
  end

  local config = require("sia.config")
  local chat_options = config.options.settings.chat

  agent.meta.current.parent = {
    agent_id = agent.id,
    conversation = agent.meta.parent,
  }

  local strategy = require("sia.strategy").new_chat(
    agent.meta.current,
    chat_options,
    { render_all = true }
  )
  agent.status = "opened"
  agent.meta.strategy = strategy
end

--- Open an agent's conversation as an interactive chat.
--- If the agent is still running, toggles a flag to open when it completes.
--- If already completed, the chat opens immediately.
---
--- @param parent_conversation sia.Conversation
--- @param agent_id integer
function M.open(parent_conversation, agent_id)
  local agent = parent_conversation:get_agent(agent_id)
  if not agent then
    return
  end

  if not agent:can_open() then
    return
  end

  if agent.status == "running" then
    agent.open = not agent.open
    return
  end

  M._open_agent_chat(agent)
end

--- Complete an opened agent, sending its result back to the parent conversation.
--- Extracts the last assistant message from the opened chat and marks the agent
--- as completed so the parent can consume the result.
---
--- @param conversation sia.Conversation The opened chat's conversation
--- @return boolean
function M.complete(conversation)
  local parent = conversation.parent
  if not parent then
    return false
  end

  local agent = parent.conversation:get_agent(parent.agent_id)
  if not agent then
    return false
  end

  if agent.status ~= "opened" then
    return false
  end

  local messages = conversation:get_messages()
  local result = nil
  for i = #messages, 1, -1 do
    if messages[i].role == "assistant" and messages[i].content then
      result = vim.split(messages[i].content, "\n")
      break
    end
  end

  if not result then
    return false
  end

  agent.status = "completed"
  agent.result = result
  agent.open = false
  agent.meta = nil
  conversation.parent = nil
  return true
end

return M
