---@type integer
local CONVERSATION_ID = 1

local function new_conversation_id()
  local id = CONVERSATION_ID
  CONVERSATION_ID = CONVERSATION_ID + 1
  return id
end

--- @class sia.conversation.Stats
--- @field cost number?
--- @field quota { percent: number, label: string? }?

--- @class sia.conversation.Todo
--- @field id integer
--- @field description string
--- @field status string

--- @class sia.conversation.PendingUserMessage
--- @field content sia.Content
--- @field region sia.Region?
--- @field hide boolean?

--- @class sia.CacheControl
--- @field type "ephemeral"

--- @class sia.TextContent
--- @field type"text"
--- @field text string
--- @field cache_control sia.CacheControl?

--- @class sia.FileContent
--- @field type "file"
--- @field file { filename: string,  file_data: string, detail: "high"|"low"}
--- @field cache_control sia.CacheControl?

--- @class sia.ImageContent
--- @field type "image"
--- @field image  { url: string, detail: "high"|"low"}
--- @field cache_control sia.CacheControl?

--- @alias sia.MultiPart sia.TextContent|sia.FileContent|sia.ImageContent
--- @alias sia.Content (sia.MultiPart)[]|string

--- @class sia.ToolSummaryParts
--- @field header string
--- @field details string?
---
--- @alias sia.ToolSummary string|sia.ToolSummaryParts

--- @class sia.BaseToolCall
--- @field key string?
--- @field id string
--- @field call_id string?
--- @field name string

--- @class sia.FunctionCall : sia.BaseToolCall
--- @field type "function"
--- @field arguments string

--- @class sia.CustomCall : sia.BaseToolCall
--- @field type "custom"
--- @field input string

--- @alias sia.ToolCall sia.FunctionCall|sia.CustomCall

--- @class sia.tool.BaseType
--- @field description string

--- @class sia.tool.Number : sia.tool.BaseType
--- @field type "number"

--- @class sia.tool.String : sia.tool.BaseType
--- @field type "string"
--- @field enum string[]?

--- @class sia.tool.Object : sia.tool.BaseType
--- @field type "object"
--- @field required string[]?
--- @field properties table<string, sia.tool.Type>

--- @class sia.tool.Array : sia.tool.BaseType
--- @field type "array"
--- @field items sia.tool.Type

--- @class sia.tool.Boolean : sia.tool.BaseType
--- @field type "boolean"

--- @class sia.tool.Integer : sia.tool.BaseType
--- @field type "integer"

--- @alias sia.tool.Type sia.tool.Number|sia.tool.String|sia.tool.Object|sia.tool.Array|sia.tool.Boolean|sia.tool.Integer

--- @class sia.tool.CustomFormat
--- @field type string
--- @field syntax string?
--- @field definition string

--- @class sia.tool.BaseDefinition
--- @field name string
--- @field description string

--- @class sia.tool.FunctionDefinition : sia.tool.BaseDefinition
--- @field type "function"
--- @field required string[]
--- @field parameters table<string, sia.tool.Type>

--- @class sia.tool.CustomDefinition : sia.tool.BaseDefinition
--- @field type "custom"
--- @field format sia.tool.CustomFormat

--- @alias sia.tool.Definition sia.tool.FunctionDefinition|sia.tool.CustomDefinition

--- @class sia.tool.ExecutionContext
--- @field conversation sia.Conversation
--- @field turn_id string
--- @field cancellable sia.Cancellable?

--- @class sia.tool.Implementation
--- @field instructions string?
--- @field summary fun(args: any):sia.ToolSummary?
--- @field allow_parallel (fun(args: any, conversation: sia.Conversation):boolean)?
--- @field is_supported (fun(model: sia.Model):boolean)?
--- @field execute fun(args: any, callback: fun(res: sia.ToolResult?), opts: sia.tool.ExecutionContext)

--- @class sia.Tool
--- @field implementation sia.tool.Implementation
--- @field definition sia.tool.Definition

--- @alias sia.ToolParameter { type: "number"|"string"|"array"|nil, items: { type: string }?, enum: string[]?, description: string? }

--- @class sia.Stale
--- @field content string
--- @field input (fun(t: sia.ToolCall):sia.ToolCall)?

--- @class sia.Region
--- @field buf integer
--- @field pos [integer,integer]?
--- @field idempotent boolean?
--- @field stale sia.Stale?

--- @class sia.TrackedRegion
--- @field buf integer
--- @field pos [integer,integer]?
--- @field idempotent boolean?
--- @field stale sia.Stale?
--- @field tick integer?

--- @class sia.Invocation
--- @field buf integer
--- @field win integer?
--- @field mode "n"|"v"
--- @field bang boolean?
--- @field cursor integer[]?
--- @field pos [integer, integer]?

--- @class sia.SystemMessage
--- @role "system"
--- @field content string

--- @class sia.UserMessage
--- @field role "user"
--- @field content sia.Content

--- @class sia.AssistantMessage
--- @field role "assistant"
--- @field content string?
--- @field reasoning sia.Reasoning?
--- @field tool_call sia.ToolCall?

--- @class sia.ToolMessage
--- @field role "tool"
--- @field content sia.Content
--- @field tool_call sia.ToolCall

--- @alias sia.Message sia.UserMessage|sia.AssistantMessage|sia.ToolMessage|sia.SystemMessage

--- @class sia.BaseEntry
--- @field id string
--- @field turn_id string?
--- @field content sia.Content?
--- @field dropped boolean
--- @field hide boolean
local BaseEntry = {}
BaseEntry.__index = BaseEntry

--- @class sia.NewBaseEntry
--- @field turn_id string
--- @field content sia.Content?
--- @field ephemeral boolean?
--- @field hide boolean?

--- @param args sia.NewBaseEntry
function BaseEntry.new(args)
  return setmetatable({
    id = require("sia.utils").new_uuid(),
    turn_id = args.turn_id,
    content = args.content,
    ephemeral = args.ephemeral or false,
    hide = args.hide or false,
  }, BaseEntry)
end

--- @class sia.SystemEntry : sia.BaseEntry
--- @field role "system"
local SystemEntry = setmetatable({}, { __index = BaseEntry })
SystemEntry.__index = SystemEntry

--- @param content (string|sia.Content)?
function SystemEntry.new(content)
  local self = setmetatable(
    BaseEntry.new({ turn_id = require("sia.utils").new_uuid(), content = content }),
    SystemEntry
  )
  self.role = "system"
  return self
end

--- @class sia.UserEntry : sia.BaseEntry
--- @field role "user"
--- @field region sia.TrackedRegion?
local UserEntry = setmetatable({}, { __index = BaseEntry })
UserEntry.__index = UserEntry

--- @param content sia.Content?
--- @param region sia.TrackedRegion?
--- @param hide boolean?
--- @param turn_id string?
function UserEntry.new(content, region, hide, turn_id)
  local self = setmetatable(
    BaseEntry.new({
      turn_id = turn_id or require("sia.utils").new_uuid(),
      content = content,
      hide = hide == true,
    }),
    UserEntry
  )
  self.role = "user"
  self.region = region
  self.dropped = false
  return self --[[@as sia.UserEntry]]
end

--- @class sia.Reasoning
--- @field text string
--- @field opaque any?

--- @class sia.AssistantEntry : sia.BaseEntry
--- @field role "assistant"
--- @field content sia.Content?
--- @field reasoning sia.Reasoning?
local AssistantEntry = setmetatable({}, { __index = BaseEntry })
AssistantEntry.__index = AssistantEntry

--- @class sia.NewAssistantEntry
--- @field turn_id string
--- @field reasoning sia.Reasoning?

--- @param content sia.Content?
--- @param args sia.NewAssistantEntry
function AssistantEntry.new(content, args)
  local self = setmetatable(
    BaseEntry.new({ turn_id = args.turn_id, content = content }),
    AssistantEntry
  )
  self.role = "assistant"
  self.reasoning = args.reasoning
  self.dropped = false
  return self
end

--- @class sia.ToolEntry : sia.BaseEntry
--- @field role "tool"
--- @field content sia.Content?
--- @field summary sia.ToolSummary?
--- @field region sia.TrackedRegion?
--- @field tool_call sia.ToolCall
--- @field ephemeral boolean
local ToolEntry = setmetatable({}, { __index = BaseEntry })
ToolEntry.__index = ToolEntry

--- @class sia.NewToolEntry
--- @field turn_id string
--- @field tool_call sia.ToolCall
--- @field ephemeral boolean?
--- @field region sia.TrackedRegion?

--- @param content sia.Content?
--- @param summary sia.ToolSummary?
--- @param args sia.NewToolEntry
function ToolEntry.new(content, summary, args)
  local self = setmetatable(
    BaseEntry.new({
      turn_id = args.turn_id,
      content = content,
    }),
    ToolEntry
  )
  self.role = "tool"
  self.tool_call = args.tool_call
  self.ephemeral = args.ephemeral
  self.region = args.region
  self.summary = summary
  return self
end

--- @alias sia.Entry sia.SystemEntry|sia.UserEntry|sia.AssistantEntry|sia.ToolEntry

--- @param mode sia.ActiveMode
--- @return string[]
local function create_enter_mode_prompt(mode)
  local prompt = {}
  table.insert(prompt, string.format("You are now in **%s** mode.", mode.name))

  local perms = mode.definition.permissions
  if perms then
    if perms.deny and #perms.deny > 0 then
      table.insert(
        prompt,
        string.format("- Denied tools: %s", table.concat(perms.deny, ", "))
      )
    end
    if perms.allow then
      local restricted = {}
      for tool, restricted_to in pairs(perms.allow) do
        if type(restricted_to) == "table" then
          table.insert(restricted, { tool = tool, restriction = restricted_to })
        end
      end
      if #restricted > 0 then
        for _, restriction in ipairs(restricted) do
          table.insert(
            prompt,
            string.format(
              "- Restricted tool: %s to %s",
              restriction.tool,
              vim.json.encode(restriction.restriction)
            )
          )
        end
      end
    end
  end

  return prompt
end

--- @class sia.Conversation
--- @field uuid string
--- @field id integer
--- @field entries sia.Entry[]
--- @field tool_definitions sia.tool.Definition[]
--- @field tool_implementation table<string, sia.tool.Implementation>
--- @field name string
--- @field model sia.Model
--- @field todos  {items: sia.conversation.Todo[]}
--- @field ignore_tool_confirm boolean?
--- @field auto_confirm_tools table<string, integer>
--- @field usage_history sia.Usage[]
--- @field agents table<integer, sia.agents.Agent>
--- @field bash_processes table<integer, sia.process.Process>
--- @field logger sia.history.HistoryLogger
--- @field tracker sia.Tracker
--- @field active_mode sia.ActiveMode?
--- @field modes table<string, sia.config.Mode>?
--- @field parent { agent_id: integer, conversation: sia.Conversation }?
--- @field pending_user_messages sia.conversation.PendingUserMessage[]
local Conversation = {}

Conversation.__index = Conversation
Conversation.pending_messages = {}

--- @class sia.NewConversationArgs
--- @field model sia.Model
--- @field ignore_tool_confirm boolean?
--- @field temporary boolean?
--- @field tools sia.Tool[]?
--- @field modes table<string, sia.config.Mode>?

--- @param opts sia.NewConversationArgs
--- @return sia.Conversation
function Conversation.new(opts)
  local obj = setmetatable({}, Conversation)
  obj.model = opts.model
  obj.id = new_conversation_id()
  obj.name = string.format("**%d**", obj.id)
  obj.uuid = require("sia.utils").new_uuid()
  obj.logger = require("sia.history").new(opts.temporary ~= true and obj.uuid or nil)
  if obj.model then
    obj.logger:created(obj.model)
  end
  obj.tracker = require("sia.tracker").new()

  obj.entries = {}
  obj.ignore_tool_confirm = opts.ignore_tool_confirm
  obj.auto_confirm_tools = {}
  obj.todos = {
    items = {},
  }
  obj.usage_history = {}
  obj.agents = {}
  obj.bash_processes = {}
  obj.pending_user_messages = {}
  obj.active_mode = nil
  obj.modes = opts.modes or {}
  obj.tool_definitions = {}
  obj.tool_implementation = {}
  if opts.tools then
    for _, tool in ipairs(opts.tools) do
      local is_supported = tool.implementation.is_supported == nil
        or tool.implementation.is_supported(obj.model)
      if obj.tool_implementation[tool.definition.name] == nil and is_supported then
        obj.tool_implementation[tool.definition.name] = tool.implementation
        table.insert(obj.tool_definitions, tool.definition)
      end
    end
  end

  return obj
end

--- @private
--- @param region sia.Region
--- @return sia.TrackedRegion
function Conversation:track_region(region)
  return {
    buf = region.buf,
    pos = region.pos,
    idempotent = region.idempotent,
    stale = region.stale,
    tick = self.tracker:track(region.buf, region.pos),
  }
end

--- @private
--- @param region sia.TrackedRegion
--- @return boolean
function Conversation:is_stale(region)
  if vim.api.nvim_buf_is_loaded(region.buf) then
    return self.tracker:is_stale(region.buf, region.tick, region.pos)
  else
    return true
  end
end

--- @param content sia.Content
--- @param region sia.Region?
--- @param opts {hide: boolean?, turn_id: string?}?
--- @return sia.UserEntry
function Conversation:add_user_message(content, region, opts)
  if region then
    self:outdate_overlapping_entries(region)
  end

  opts = opts or {}
  local entry = UserEntry.new(content, region and self:track_region(region), opts.hide)
  table.insert(self.entries, entry)
  return entry
end

--- @param content sia.Content
--- @param region sia.Region?
--- @param hide boolean?
function Conversation:add_pending_user_message(content, region, hide)
  table.insert(self.pending_user_messages, {
    content = content,
    region = region,
    hide = hide,
  })
end

--- @return integer
function Conversation:pending_user_message_count()
  return #self.pending_user_messages
end

--- @return boolean
function Conversation:has_pending_user_messages()
  return self:pending_user_message_count() > 0
end

function Conversation:clear_pending_user_messages()
  self.pending_user_messages = {}
end

--- @param turn_id string?
--- @return sia.Entry[]?
function Conversation:attach_pending_user_messages(turn_id)
  if not self:has_pending_user_messages() then
    return nil
  end

  local messages = self.pending_user_messages
  self.pending_user_messages = {}

  --- @type sia.Entry[]
  local visible = {}
  for _, message in ipairs(messages) do
    local entry = self:add_user_message(
      message.content,
      message.region,
      { hide = message.hide, turn_id = turn_id }
    )
    if not message.hide then
      table.insert(visible, entry)
    end
  end

  return visible
end

--- @param turn_id string
--- @param content string
--- @param reasoning sia.Reasoning?
function Conversation:add_assistant_message(turn_id, content, reasoning)
  local message = AssistantEntry.new(content, {
    turn_id = turn_id,
    reasoning = reasoning,
  })
  table.insert(self.entries, message)
end

--- @param content string
function Conversation:add_system_message(content)
  table.insert(self.entries, SystemEntry.new(content))
end

--- @param turn_id string
--- @param tool sia.ToolCall
--- @param content sia.Content
--- @param opts {summary: sia.ToolSummary?, ephemeral: boolean, region: sia.Region?}?
function Conversation:add_tool_message(turn_id, tool, content, opts)
  opts = opts or {}
  if opts.region and not opts.ephemeral then
    self:outdate_overlapping_entries(opts.region)
  end
  local tool_msg = ToolEntry.new(content, opts.summary, {
    turn_id = turn_id,
    tool_call = tool,
    ephemeral = opts.ephemeral,
    region = opts.region and self:track_region(opts.region),
  })
  table.insert(self.entries, tool_msg)
end

--- @param name string
--- @return boolean
function Conversation:has_tool(name)
  return self.tool_implementation[name] ~= nil
end

--- @param name string
--- @return sia.config.Mode?
function Conversation:get_mode(name)
  return self.modes and self.modes[name] or nil
end

function Conversation:has_mode(name)
  return name == "default" or self:get_mode(name) ~= nil
end

--- @param name string
--- @return { content: string, truncate_after_id: string? }?
function Conversation:enter_mode(name)
  --- @type string[]
  local content = {}
  if name == "default" then
    if self.active_mode then
      return self:exit_mode()
    end
    return nil
  end

  local definition = self:get_mode(name)
  if not definition then
    return nil
  end

  --- @type string?
  local truncate_after_id

  if self.active_mode then
    local exit_info = self:exit_mode()
    if exit_info then
      truncate_after_id = exit_info.truncate_after_id
      if exit_info.content then
        table.insert(content, exit_info.content)
      end
    end
  end

  local active = require("sia.permissions").create_active_mode(name, definition)
  self.active_mode = active

  local prompt = create_enter_mode_prompt(active)
  if self:has_tool("exit_mode") then
    table.insert(prompt, "- Use `exit_mode` when the mode's objective is complete.")
  end
  if type(definition.enter_prompt) == "function" then
    table.insert(prompt, definition.enter_prompt(active.state))
  else
    local render =
      require("sia.template").render(tostring(definition.enter_prompt), active.state)
    table.insert(prompt, render)
  end

  active.truncate_after_id = self.entries[#self.entries].id
  table.insert(content, table.concat(prompt, "\n"))
  return { truncate_after_id = truncate_after_id, content = table.concat(content, "\n") }
end

--- @param summary string?
--- @return { content: string, truncate_after_id: string? }?
function Conversation:exit_mode(summary)
  local active = self.active_mode
  if not active then
    return nil
  end

  local definition = active.definition
  --- @type string[]
  local prompt = summary and { summary } or {}
  if type(definition.exit_prompt) == "function" then
    table.insert(prompt, definition.exit_prompt(active.state))
  else
    table.insert(
      prompt,
      require("sia.template").render(tostring(definition.exit_prompt), active.state)
    )
  end

  local info = { content = table.concat(prompt, "\n") }
  if definition.truncate and active.truncate_after_id then
    info.truncate_after_id = active.truncate_after_id
  end

  self.active_mode = nil
  return info
end

--- Drop every message after message_id
--- @param message_id string
function Conversation:drop_after(message_id)
  local start_index = nil
  for i, message in ipairs(self.entries) do
    if message.id == message_id then
      start_index = i
      break
    end
  end

  if not start_index then
    return
  end

  for i = start_index + 1, #self.entries do
    local message = self.entries[i]
    if not message.dropped then
      message.dropped = true
    end
  end
end

--- TODO: rename
function Conversation:is_buf_valid(buf)
  local is_valid = false
  for _, message in ipairs(self.entries) do
    if message.region and message.region.buf == buf then
      is_valid = not self:is_stale(message.region)
    end
  end
  return is_valid
end

function Conversation:untrack_messages()
  self.tracker:destroy()
end

---@return string turn_id
function Conversation:new_turn()
  local turn_id = require("sia.utils").new_uuid()
  self.entries[#self.entries].turn_id = turn_id
  return turn_id
end

--- Get the turn_id of the last (most recent) turn.
--- @return string? turn_id The last turn_id, or nil if no turns exist
function Conversation:last_turn_id()
  for i = #self.entries, 1, -1 do
    local message = self.entries[i]
    if message.turn_id and not message.dropped then
      return message.turn_id
    end
  end
  return nil
end

--- Get all active turn_ids in order.
--- @return string[]
function Conversation:turn_ids()
  local ids = {}
  local seen = {}
  for _, message in ipairs(self.entries) do
    if message.turn_id and not seen[message.turn_id] and not message.dropped then
      seen[message.turn_id] = true
      table.insert(ids, message.turn_id)
    end
  end
  return ids
end

--- Get all active messages before the given turn_id.
--- Returns messages that are not dropped and appear before the first message
--- with the matching turn_id.
--- @param turn_id string
--- @return sia.Entry[]? messages nil if turn_id not found
function Conversation:get_entries_until(turn_id)
  local result = {}
  for _, message in ipairs(self.entries) do
    if message.turn_id == turn_id then
      return result
    end
    if not message.dropped then
      table.insert(result, message)
    end
  end
  return nil
end

--- @param turn_id string The turn_id to rollback (this turn and all after it are dropped)
--- @return string[]? dropped_turn_ids List of unique dropped turn_ids, or nil if turn not found
function Conversation:rollback_to(turn_id)
  local target_index = nil
  for i, message in ipairs(self.entries) do
    if message.turn_id == turn_id then
      target_index = i
      break
    end
  end

  if not target_index then
    return nil
  end

  local dropped_turn_ids = {}
  local seen = {}
  for i = target_index, #self.entries do
    local message = self.entries[i]
    if not message.dropped then
      message.dropped = true
    end
    if message.turn_id and not seen[message.turn_id] then
      seen[message.turn_id] = true
      table.insert(dropped_turn_ids, message.turn_id)
    end
  end

  return dropped_turn_ids
end

function Conversation:destroy()
  self:untrack_messages()
  for _, proc in ipairs(self.bash_processes) do
    if proc.status == "running" and proc.detached_handle then
      proc.detached_handle.kill()
    end
  end

  if self.shell then
    self.shell:close()
    self.shell = nil
  end

  self.bash_processes = {}

  -- If the conversation was opened from an agent
  if self.parent then
    local agent = self.parent.conversation:get_agent(self.parent.agent_id)
    -- We have to make sure that the agent we opened from
    -- no longer carries a reference to this conversation
    if agent then
      agent:close()
    end
  end

  -- We also need to ensure that all agents that
  -- have this conversation as parent are no longer opened.
  -- Instead we mark them as cancelled
  for _, agent in ipairs(self.agents) do
    agent:close()
  end

  require("sia.ui.confirm").clear(self.id)
  self.logger:destroyed()
end

--- @param name string
--- @param task string
--- @param source "tool"|"user"
--- @return sia.agents.Agent
function Conversation:new_agent(name, task, source)
  local task_id = #self.agents + 1
  local agent = require("sia.agents").new(task_id, name, task, source)
  table.insert(self.agents, agent)
  return agent
end

--- @return sia.agents.Agent
--- @param id integer
--- @return sia.agents.Agent?
function Conversation:get_agent(id)
  return self.agents[id]
end

--- @return boolean any_attached True if any agents were attached
function Conversation:attach_completed_agents()
  local attached_any = false
  for _, agent in ipairs(self.agents) do
    if agent.source == "user" and agent.status == "completed" and agent.result then
      local content = {
        string.format(
          "Background agent '%s' (id: %d) completed with the following result:",
          agent.name,
          agent.id
        ),
        string.format("Task: %s", agent.task),
        "",
      }
      vim.list_extend(content, agent.result)
      self:add_user_message(table.concat(content, "\n"), nil, { hide = true })
      agent.status = "attached"
      agent.meta = nil
      attached_any = true
    end
  end
  return attached_any
end

--- @param command string
--- @param description string?
--- @return sia.process.Process
function Conversation:new_bash_process(command, description)
  local proc_id = #self.bash_processes + 1
  local process = require("sia.process").new(proc_id, command, description)
  process._conversation_id = self.id
  table.insert(self.bash_processes, process)
  return process
end

--- @param id integer
--- @return sia.process.Process?
function Conversation:get_bash_process(id)
  return self.bash_processes[id]
end

--- Check if the new interval completely encompasses an existing interval
--- Returns true if the existing interval should be masked (new is superset of existing)
--- @param new_region sia.Region
--- @param old_region sia.TrackedRegion
--- @return boolean
local function is_region_overlapping(new_region, old_region)
  if not old_region.idempotent then
    return false
  end

  if new_region.buf ~= old_region.buf then
    return false
  end

  if not new_region.pos then
    return true
  end

  if not old_region.pos then
    return false
  end

  local new_start, new_end = new_region.pos[1], new_region.pos[2]
  local existing_start, existing_end = old_region.pos[1], old_region.pos[2]

  return new_start <= existing_start and existing_end <= new_end
end

--- @private
--- @param region sia.Region
function Conversation:outdate_overlapping_entries(region)
  if not region.idempotent then
    return
  end

  local entries_to_remove = {}
  for i, message in ipairs(self.entries) do
    local old_region = message.region
    if old_region and (message.role == "user" or message.role == "tool") then
      if is_region_overlapping(region, old_region) then
        entries_to_remove[i] = true
      end
    end
  end

  local is_overlap = false
  local new_entries = {}
  for i, entry in ipairs(self.entries) do
    if entries_to_remove[i] then
      is_overlap = true
    else
      new_entries[#new_entries + 1] = entry
    end
  end
  if is_overlap then
    self.entries = new_entries
  end
end

--- @return sia.Entry message
function Conversation:get_last_entry()
  return self.entries[#self.entries]
end

--- @param name string
--- @param arguments table
--- @param opts {cancellable: sia.Cancellable?, callback:  fun(opts: sia.ToolResult?), turn_id: string? }
--- @return string[]?
function Conversation:execute_tool(name, arguments, opts)
  if self:has_tool(name) then
    local ok, err =
      pcall(self.tool_implementation[name].execute, arguments, opts.callback, {
        cancellable = opts.cancellable,
        turn_id = opts.turn_id,
        conversation = self,
      })
    if not ok then
      print(vim.inspect(err))
      opts.callback({ content = "Tool execution failed. ", ephemeral = true })
    end
    return
  else
    opts.callback(nil)
  end
end

--- @return sia.TrackedRegion[]
function Conversation:get_regions()
  local regions = {}
  for _, message in ipairs(self.entries) do
    if message.role == "user" or message.role == "tool" then
      local region = message.region
      if region and not self:is_stale(message.region) then
        table.insert(regions, region)
      end
    end
  end
  return regions
end

--- Add usage statistics from a request/response cycle
--- @param usage sia.Usage
function Conversation:add_usage(usage)
  table.insert(self.usage_history, usage)
  self.logger:usage_created(usage)
end

--- Get cumulative usage across all requests in this conversation
--- @return sia.Usage
function Conversation:get_cumulative_usage()
  --- @type sia.Usage
  local cumulative = {
    input = 0,
    output = 0,
    cache_read = 0,
    cache_write = 0,
    total = 0,
    total_time = 0,
  }

  for _, usage in ipairs(self.usage_history) do
    cumulative.input = cumulative.input + (usage.input or 0)
    cumulative.cache_read = cumulative.cache_read + (usage.cache_read or 0)
    cumulative.cache_write = cumulative.cache_write + (usage.cache_write or 0)
    cumulative.output = cumulative.output + (usage.output or 0)
    cumulative.total = cumulative.total + (usage.total or 0)
  end

  return cumulative
end

--- Persist the current state of the conversation into a new round.
--- Called once per round.
--- @return sia.Message[]
function Conversation:serialize()
  --- @type sia.Message[]
  local messages = {}

  for _, entry in ipairs(self.entries) do
    if not entry.dropped then
      if entry.ephemeral then
        entry.dropped = true
      end
      if entry.role == "system" then
        table.insert(messages, { role = "system", content = entry.content })
      elseif entry.role == "user" and entry.content then
        local message = { role = "user", content = entry.content }
        if entry.region and self:is_stale(entry.region) then
          message.content = string.format(
            "System Note: History pruned. %s",
            entry.region.stale and entry.region.stale.content or ""
          )
        end
        table.insert(messages, message)
      elseif entry.role == "assistant" and (entry.content or entry.reasoning) then
        local message = {
          role = "assistant",
          content = entry.content,
          reasoning = entry.reasoning,
        }
        table.insert(messages, message)
      elseif entry.role == "tool" and entry.content then
        local assistant_message = { role = "assistant" }
        local tool_message = { role = "tool", tool_call = entry.tool_call }
        local stale = entry.region and self:is_stale(entry.region)
        if stale then
          tool_message.content = string.format(
            "System Note: History pruned. %s",
            entry.region.stale and entry.region.stale.content or ""
          )
        else
          tool_message.content = entry.content
        end

        if stale and entry.region.stale.input then
          assistant_message.tool_call = entry.region.stale.input(entry.tool_call)
        else
          assistant_message.tool_call = entry.tool_call
        end
        table.insert(messages, assistant_message)
        table.insert(messages, tool_message)
      end
    end
  end
  return messages
end

--- @param source sia.Conversation
--- @param turn_id string
--- @return sia.Conversation?
local function fork_conversation(source, turn_id)
  local entries = source:get_entries_until(turn_id)
  if not entries then
    return nil
  end

  local conversation = Conversation.new({
    model = source.model,
    ignore_tool_confirm = source.ignore_tool_confirm,
    tools = source.tools, -- TODO: fix me!
    modes = source.modes,
  })
  if source.active_mode then
    conversation.active_mode = nil
  end

  for _, entry in ipairs(entries) do
    local entry_copy = vim.deepcopy(entry)
    if entry_copy.region and entry_copy.region.tick then
      entry_copy.dropped = true
    end
    table.insert(conversation.entries, entry_copy)
  end

  return conversation
end

--- @param conversation sia.Conversation
local function new_template_context(conversation)
  local agents = require("sia.agents.registry").get_agents(false)
  local agent_list = {}
  for _, agent in pairs(agents) do
    table.insert(agent_list, agent)
  end

  local has_tool = function(name)
    return conversation.tool_implementation[name] ~= nil
  end
  local skills = require("sia.skills.registry").get_skills(has_tool, false)
  local skill_list = {}
  for _, skill in ipairs(skills) do
    table.insert(skill_list, {
      name = skill.name,
      description = skill.description,
      content = table.concat(skill.content, "\n"),
      filepath = skill.filepath,
      dir = skill.dir,
    })
  end
  return {
    today = os.date("%Y-%m-%d"),
    tools = conversation.tool_definitions,
    agents = agent_list,
    has_tools = #conversation.tool_definitions > 0,
    tool_count = #conversation.tool_definitions,
    model = conversation.model,
    skills = skill_list,
    has_skills = #skill_list > 0,
    has_tool = has_tool,
  }
end

--- @param action sia.config.Action
--- @param invocation sia.Invocation
--- @param overrides {model: string?}?
--- @return sia.Conversation
local function from_action(action, invocation, overrides)
  overrides = overrides or {}
  local config = require("sia.config")
  local model = require("sia.model").resolve(
    overrides.model or action.model or config.options.settings.model
  )
  local conversation = Conversation.new({
    model = model,
    tools = action.tools and action.tools(model),
    modes = action.modes,
  })

  local template = require("sia.template")
  local template_context = new_template_context(conversation)
  for _, system in ipairs(action.system or {}) do
    local content = type(system) == "function" and system()
      or template.render(system --[[@as string]], template_context)
    conversation:add_system_message(content)
  end
  for _, user in ipairs(action.user or {}) do
    if type(user) == "function" then
      local content, region = user(invocation)
      if content then
        conversation:add_user_message(content, region, { hide = true })
      end
    elseif type(user) == "string" then
      conversation:add_user_message(user)
    elseif type(user) == "table" and user.content then
      if type(user.content) == "function" then
        local content, region = user.content(invocation)
        if content then
          conversation:add_user_message(content, region, { hide = user.hide })
        end
      else
        conversation:add_user_message(
          user.content --[[@as sia.Content]],
          nil,
          { hide = user.hide }
        )
      end
    else
      conversation:add_user_message(user --[[@as sia.Content]])
    end
  end
  return conversation
end

return {
  new_conversation = Conversation.new,
  fork_conversation = fork_conversation,
  from_action = from_action,
}
