local M = {}

--- Spawn a registered agent in the background, attached to a parent conversation.
---
--- Creates a new hidden conversation with the agent's configured tools and model,
--- adds the system prompt and user task, then executes it via HiddenStrategy.
--- The agent is tracked on `parent_conversation.agents[]`.
---
--- @class sia.agents.SpawnOpts
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

  local agent = parent_conversation:new_agent(agent_name, task)
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

  local strategy = require("sia.strategy").new_hidden(nil, new_conversation, {
    notify = function(msg)
      agent.progress = msg
      if opts.on_progress then
        opts.on_progress(agent, msg)
      end
    end,
    callback = function(_, result)
      if
        not result.error
        and not (agent.cancellable and agent.cancellable.is_cancelled)
      then
        agent.status = "completed"
        agent.result = result.content or { "No response" }
        agent.progress = nil
      else
        agent.status = "failed"
        agent.error = result.error
        agent.progress = nil
      end
      agent.usage = result.usage
      if opts.on_complete then
        opts.on_complete(agent)
      end
    end,
  }, agent.cancellable)

  require("sia.assistant").execute_strategy(strategy)
  return agent
end

return M
