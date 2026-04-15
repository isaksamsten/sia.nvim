--- @class sia.agents.Agent
--- @field id integer
--- @field source "tool"|"user"
--- @field status "running"|"idle"|"pending"|"failed"|"cancelled"
--- @field view "open"|"closed"|"pending"
--- @field progress string?
--- @field error string?
--- @field name string
--- @field task string
--- @field started_at number
--- @field conversation sia.Conversation
--- @field background sia.HiddenStrategy
--- @field foreground sia.ChatStrategy?
--- @field cancellable sia.Cancellable?
local Agent = {}
Agent.__index = Agent

--- @param id integer
--- @param name string
--- @param task string
--- @param source "tool"|"user"
--- @return sia.agents.Agent
function Agent.new(id, name, task, source)
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
    if self.view == "pending" then
      table.insert(content, "Will open as chat on completion.")
    end
    if self.progress and #self.progress > 0 then
      table.insert(content, string.format("Progress: %s", self.progress))
    end
    if self.cancellable and self.cancellable.is_cancelled then
      table.insert(content, "Cancellation requested: yes")
    end
  elseif self.status == "idle" then
    table.insert(content, "Idle")
  elseif self.status == "pending" then
    table.insert(content, "Result is ready to attach.")
  elseif self.status == "cancelled" then
    table.insert(content, "Cancelled by user.")
  elseif self.status == "failed" and self.error then
    table.insert(content, "")
    table.insert(content, string.format("Error: %s", self.error))
  end

  return table.concat(content, "\n")
end

--- @class sia.agents.SpawnOpts
--- @field source "tool"|"user"? Source of the spawn (default: "user")
--- @field workspace string?
--- @field on_complete (fun(agent: sia.agents.Agent))? Called when the agent finishes (success or failure)
--- @field on_progress (fun(agent: sia.agents.Agent, msg: string))? Called on progress updates

--- @class sia.agents.Runtime
--- @field items sia.agents.Agent[]
local Runtime = {}
Runtime.__index = Runtime

--- @private
--- @param agent_def sia.agents.registry.Agent
--- @param agent sia.agents.Agent
--- @param workspace string?
--- @return sia.Conversation
local function create_conversation(agent_def, agent, workspace)
  local config = require("sia.config")
  local tools = require("sia.tools")

  local conversation = require("sia.conversation").new({
    model = require("sia.model").resolve(
      agent_def.model or config.options.settings.fast_model
    ),
    approved_tools = agent_def.auto_approve,
    workspace = workspace,
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

  local system_prompt = require("sia.template").render(
    table.concat(agent_def.system_prompt, "\n"),
    { workspace = workspace }
  )
  conversation:add_system_message(system_prompt)
  conversation:add_user_message(agent.task)
  return conversation
end

--- @param agent sia.agents.Agent
local function create_foreground(agent)
  local config = require("sia.config")
  local chat_options = config.options.settings.chat

  local set_idle = function()
    agent.status = "idle"
  end
  agent.foreground =
    require("sia.strategy").new_chat(agent.conversation, chat_options, {
      render_all = true,
      destroy = false,
      hooks = {
        on_cancel = set_idle,
        on_error = set_idle,
        on_finish = set_idle,
        on_close = function()
          agent.view = "closed"
        end,
      },
    })
  agent.view = "open"
  agent.status = "idle"
  vim.keymap.set("n", "i", function()
    agent.status = "pending"
  end, { buffer = agent.foreground.buf })
end

--- @param name string
--- @param task string
--- @param source "tool"|"user"
--- @return sia.agents.Agent
function Runtime:create(name, task, source)
  local agent_id = #self.items + 1
  local agent = Agent.new(agent_id, name, task, source)
  table.insert(self.items, agent)
  return agent
end

--- @param agent_name string
--- @param task string
--- @param opts sia.agents.SpawnOpts?
--- @return sia.agents.Agent?
function Runtime:spawn(agent_name, task, opts)
  opts = opts or {}

  local agent_def = require("sia.agent.registry").get(agent_name)
  if not agent_def then
    return nil
  end

  local agent = self:create(agent_name, task, opts.source or "user")
  agent.conversation = create_conversation(agent_def, agent, opts.workspace)
  agent.view = agent_def.interactive and "pending" or "closed"

  agent.background = require("sia.strategy").new_hidden(nil, agent.conversation, {
    notify = function(msg)
      agent.progress = msg
      if opts.on_progress then
        opts.on_progress(agent, msg)
      end
    end,
    callback = function(_, result)
      agent.progress = nil
      if
        agent.status == "cancelled"
        or (agent.cancellable and agent.cancellable.is_cancelled)
      then
        agent.status = "cancelled"
        agent.error = "Cancelled by user"
        if opts.on_complete then
          opts.on_complete(agent)
        end
        return
      end

      if result.error then
        agent.status = "failed"
        agent.error = result.error
        if opts.on_complete then
          opts.on_complete(agent)
        end
        return
      end
      if agent.view == "pending" then
        agent.status = "idle"
        vim.schedule(function()
          create_foreground(agent)
        end)
        return
      end

      agent.status = "pending"
      if opts.on_complete then
        opts.on_complete(agent)
      end
    end,
  }, agent.cancellable)

  require("sia.assistant").execute_strategy(agent.background)
  return agent
end

--- @param id integer
--- @param content string
function Runtime:submit(id, content)
  local agent = self:get(id)
  if not agent then
    return
  end

  if agent.status == "failed" then
    return
  end

  if agent.status == "pending" then
    return
  end

  agent.progress = nil
  agent.error = nil
  agent.status = "running"

  if agent.view == "open" then
    agent.foreground:submit({ content = content })
  else
    agent.background:submit(content)
  end
end

--- @param id integer
--- @return sia.agents.Agent?
function Runtime:get(id)
  return self.items[id]
end

--- @return sia.agents.Agent[]
function Runtime:list()
  return self.items
end

--- @param f fun(agent: sia.agents.Agent):boolean
--- @return sia.agents.Agent?
function Runtime:find(f)
  return vim.iter(self.items):find(f)
end

--- @param f fun(agent: sia.agents.Agent):boolean
--- @return boolean
function Runtime:any(f)
  return vim.iter(self.items):any(f)
end

--- @param id integer
--- @return boolean
function Runtime:can_open(id)
  local agent = self:get(id)
  return agent ~= nil and agent.view ~= "open"
end

--- @param id integer
function Runtime:open(id)
  local agent = self:get(id)
  if not agent then
    return
  end

  if agent.status == "running" then
    agent.view = "pending"
    return
  end

  create_foreground(agent)
end

function Runtime:close(id)
  local agent = self:get(id)
  if not agent then
    return
  end

  if agent.status == "running" then
    agent.view = "closed"
    return
  end

  if agent.view == "open" and agent.foreground then
    agent.view = "closed"
    require("sia.strategy").remove_chat(agent.foreground.buf)
    agent.foreground = nil
  end
end

--- @param id integer
function Runtime:stop(id)
  local agent = self:get(id)
  if not agent then
    return
  end

  if agent.status == "cancelled" then
    return
  end

  if agent.cancellable then
    agent.cancellable.is_cancelled = true
  end

  agent.progress = "Cancellation requested"
  agent.status = "cancelled"
  agent.error = "Cancelled by user"
end

--- @return { agent: sia.agents.Agent, content: string }[]
function Runtime:collect_completed()
  local results = {}
  for _, agent in ipairs(self.items) do
    if agent.source == "user" and agent.status == "pending" then
      local content = {
        string.format(
          "Background agent '%s' (id: %d) completed with the following result:",
          agent.name,
          agent.id
        ),
        string.format("Task: %s", agent.task),
        "",
      }
      local assistant_content = agent.conversation:get_last_assistant_content()
      if assistant_content then
        table.insert(content, assistant_content)
      end
      agent.status = "idle"
      table.insert(results, {
        agent = agent,
        content = table.concat(content, "\n"),
      })
    end
  end
  return results
end

function Runtime:destroy()
  for _, agent in ipairs(self.items) do
    if agent.cancellable then
      agent.cancellable.is_cancelled = true
    end
    agent.background = nil
    agent.foreground = nil
    agent.conversation = nil
  end
  self.items = {}
end

return {
  --- @return sia.agents.Runtime
  new_runtime = function()
    return setmetatable({
      items = {},
    }, Runtime)
  end,
}
