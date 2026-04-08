local M = {}

--- Spawn a registered agent in the background, attached to a parent conversation.
---
--- Creates a new hidden conversation with the agent's configured tools and model,
--- adds the system prompt and user task, then executes it via HiddenStrategy.
--- The agent is tracked on `parent_conversation.agents[]`.
---
--- @class sia.agents.SpawnOpts
--- @field source "tool"|"user"? Source of the spawn (default: "user")
--- @field on_complete (fun(agent: sia.agents.Agent))? Called when the agent finishes (success or failure)
--- @field on_progress (fun(agent: sia.agents.Agent, msg: string))? Called on progress updates

--- @param agent_name string
--- @param task string
--- @param parent_conversation sia.Conversation
--- @param opts sia.agents.SpawnOpts?
--- @return sia.agents.Agent?
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

  local new_conversation = require("sia.conversation").new_conversation({
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

  new_conversation:add_system_message(table.concat(agent_def.system_prompt, "\n"))
  new_conversation:add_user_message(task)
  new_conversation.name = parent_conversation.name .. "-" .. agent.name

  agent.meta = {
    current = new_conversation,
    parent = parent_conversation,
  }
  agent.open = agent_def.interactive
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
--- @param agent sia.agents.Agent
function M._open_agent_chat(agent)
  if agent.status == "opened" or not agent.meta then
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

  local messages = conversation:serialize()
  local result = nil
  for i = #messages, 1, -1 do
    local message = messages[i]
    if message.role == "assistant" and message.content then
      result = vim.split(message.content, "\n")
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

--- @class sia.conversation.AgentMeta
--- @field parent sia.Conversation
--- @field current sia.Conversation
--- @field strategy sia.ChatStrategy?

--- @class sia.agents.Agent
--- @field id integer
--- @field source "tool"|"user"
--- @field status "running"|"completed"|"failed"|"attached"|"cancelled"|"opened"
--- @field progress string?
--- @field result string[]?
--- @field error string?
--- @field name string
--- @field task string
--- @field started_at number
--- @field usage sia.Usage?
--- @field cancellable sia.Cancellable?
--- @field open boolean
--- @field meta sia.conversation.AgentMeta?
local Agent = {}
Agent.__index = Agent

function M.new(id, name, task, source)
  return setmetatable({
    id = id,
    name = name,
    task = task,
    source = source or "tool",
    status = "running",
    started_at = vim.uv.hrtime() / 1e9,
    cancellable = { is_cancelled = false },
  }, Agent)
end

--- @return string
function Agent:get_preview()
  local content = {
    string.format("Agent ID: %d", self.id),
    string.format("Agent: %s", self.name),
    string.format("Status: %s", self.status),
    string.format("Task: %s", self.task),
  }

  if self.status == "running" then
    if self.open then
      table.insert(content, "Will open as chat on completion.")
    end
    if self.progress and #self.progress > 0 then
      table.insert(content, string.format("Progress: %s", self.progress))
    end
    if self.cancellable and self.cancellable.is_cancelled then
      table.insert(content, "Cancellation requested: yes")
    end
  elseif self.status == "opened" then
    table.insert(
      content,
      "Opened as interactive chat. Use :SiaAgent complete to send result back."
    )
  elseif self.status == "completed" and self.result then
    table.insert(content, "")
    table.insert(content, "Result:")
    vim.list_extend(content, self.result)
  elseif self.status == "failed" and self.error then
    table.insert(content, "")
    table.insert(content, string.format("Error: %s", self.error))
  end

  return table.concat(content, "\n")
end

function Agent:cancel()
  if self.status ~= "running" then
    return
  end

  if not self.cancellable then
    return
  end

  if self.cancellable.is_cancelled then
    return
  end

  self.cancellable.is_cancelled = true
  self.progress = "Cancellation requested"
end

function Agent:can_open()
  return self.status == "running" or self.status == "completed" and self.meta ~= nil
end

function Agent:close()
  if self.status == "opened" then
    self.open = nil
    self.status = "cancelled"
  end
end

return M
