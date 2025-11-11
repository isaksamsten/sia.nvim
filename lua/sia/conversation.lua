local tracker = require("sia.tracker")
local template = require("sia.template")

--- @class sia.PreparedMessage
--- @field role string
--- @field content (string|sia.InstructionContent[])?
--- @field hide boolean
--- @field outdated boolean
--- @field superseded boolean
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call sia.ToolCall?
--- @field meta table?
--- @field description string?

--- @class sia.conversation.Stats
--- @field bar { percent: number, text: string?, icon: string?}?
--- @field left string?
--- @field right string?

--- @class sia.conversation.Todo
--- @field id integer
--- @field description string
--- @field status string

--- @alias sia.CacheControl {type: "ephemeral"}
--- @alias sia.InstructionTextContent {type:"text", text: string, cache_control: sia.CacheControl?}
--- @alias sia.InstructionFileContent {type: "file", file: {filename: string, file_data: string}, cache_control: sia.CacheControl?}
--- @alias sia.InstructionImageContent {type: "image_url", image_url: {url: string, detail:"high"|"low"}, cache_control: sia.CacheControl?}
--- @alias sia.InstructionContent sia.InstructionTextContent|sia.InstructionFileContent|sia.InstructionImageContent
--- @class sia.Prompt
--- @field role sia.config.Role
--- @field content (string|sia.InstructionContent[])?
--- @field tool_calls sia.ToolCall[]?
--- @field tool_call_id string?

--- @alias sia.Tool { type: "function", function: { name: string, description: string, parameters: {type: "object", properties: table<string, sia.ToolParameter>?, required: string[]?, additionalProperties: boolean?}}}
--- @alias sia.ToolParameter { type: "number"|"string"|"array"|nil, items: { type: string }?, enum: string[]?, description: string? }

--- @class sia.Context
--- @field buf integer? buffer
--- @field win integer? window
--- @field pos [integer,integer]? 1-indexed
--- @field mode "n"|"v"? normal or visual mode
--- @field bang boolean?
--- @field cursor integer[]? 1-indexed
--- @field tick integer?
--- @field outdated_message string?
--- @field clear_outdated_tool_input (fun(t: sia.ToolCall):sia.ToolCall)?

--- @class sia.ActionContext : sia.Context
--- @field start_line integer?
--- @field end_line integer?

--- @class sia.Message
--- @field role sia.config.Role
--- @field context sia.Context?
--- @field template boolean
--- @field hide boolean?
--- @field kind string?
--- @field content (string|sia.InstructionContent[])?
--- @field content_gen fun(context: sia.Context?):string
--- @field live_content (fun():string?)
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call sia.ToolCall?
--- @field meta table?
--- @field _outdated_tool_call boolean?
--- @field description string?
--- @field superseded boolean? -- Mark message as superseded by a newer overlapping message
local Message = {}
Message.__index = Message

--- @param content_gen fun(context: sia.Context?):string?
--- @param context sia.Context?
--- @return string? content
local function generate_content(content_gen, context)
  local tmp = content_gen(context)
  if tmp then
    if type(tmp) == "table" then
      return table.concat(tmp, "\n")
    else
      return tmp
    end
  end
  return nil
end

--- @param instruction sia.config.Instruction
--- @param context sia.Context?
--- @return (string|sia.InstructionContent[])?
local function make_content(instruction, context)
  --- @type (string|sia.InstructionContent[])?
  local content
  if type(instruction.content) == "function" then
    content = generate_content(instruction.content, context)
  elseif
    type(instruction.content) == "table" and type(instruction.content[1]) == "string"
  then
    local tmp = instruction.content
    --- @cast tmp string[]
    content = table.concat(tmp, "\n")
  elseif type(instruction.content) == "table" then
    local tmp = instruction.content
    --- @cast tmp sia.InstructionContent[]
    content = tmp
  elseif instruction.content ~= nil and type(instruction.content) == "string" then
    content = instruction.content
  end
  if instruction.role == "tool" then
    content = content or nil
  end

  return content
end

--- @param instruction sia.config.Instruction
--- @param context sia.Context?
--- @return string?
local function make_description(instruction, context)
  if type(instruction.description) == "function" then
    return instruction.description(context)
  end
  return instruction.description
end

--- @param instruction sia.config.Instruction
--- @param context sia.Context?
--- @return sia.Message
function Message:from_table(instruction, context)
  local obj = setmetatable({}, self)
  obj.role = instruction.role
  obj.live_content = instruction.live_content
  obj.kind = instruction.kind

  if instruction.tool_calls then
    obj.tool_calls = instruction.tool_calls
  end
  if instruction._tool_call then
    obj._tool_call = instruction._tool_call
  end
  obj.meta = {}
  obj.template = instruction.template or false
  obj.hide = instruction.hide
  obj.content = make_content(instruction, context)
  obj.description = make_description(instruction, context)
  obj.context = context
  if type(instruction.content) == "function" then
    obj.content_gen = instruction.content
  end
  return obj
end

--- Create a new message from a stored instruction
--- @param str string|string[]
--- @param context sia.Context?
--- @return sia.Message[]?
function Message:from_string(str, context)
  if type(str) == "string" then
    local instruction = require("sia.config").options.instructions[str]
    if not instruction then
      instruction = require("sia.builtin")[str]
    end
    if instruction then
      if vim.islist(instruction) then
        local messages = {}
        for _, step in ipairs(instruction) do
          table.insert(messages, Message:from_table(step, context))
        end
        return messages
      end
      return { Message:from_table(instruction, context) }
    end
  end
end

--- Create a new message from an Instruction or a stored instruction.
--- @param instruction sia.config.Instruction|string|sia.config.Instruction[]
--- @param context sia.Context?
--- @return sia.Message[]?
function Message:new(instruction, context)
  if type(instruction) == "string" then
    return Message:from_string(instruction, context)
  elseif vim.islist(instruction) then
    local messages = {}
    for _, step in ipairs(instruction) do
      table.insert(messages, Message:from_table(step, context))
    end
    return messages
  else
    return { Message:from_table(instruction, context) }
  end
end

--- @param message sia.Message
--- @param outdated boolean?
--- @return (string|sia.InstructionContent[])?
local function get_message_content(message, outdated)
  if message.content then
    if outdated then
      return string.format(
        "System Note: History pruned. %s",
        message.context and message.context.outdated_message or ""
      )
    end
    return message.content
  elseif message.live_content then
    return message.live_content()
  else
    return nil
  end
end

function Message:has_content()
  return self.content ~= nil or self.live_content ~= nil or self.tool_calls ~= nil
end

--- @param id integer
--- @return boolean
function Message:is_outdated(id)
  if self.live_content then
    return false
  end

  if
    self.context
    and self.context.buf
    and self.context.tick
    and self.kind ~= nil
    and (self.role == "tool" or self.role ~= "assistant")
  then
    if vim.api.nvim_buf_is_loaded(self.context.buf) then
      return self.context.tick ~= tracker.user_tick(self.context.buf, id)
    else
      return true
    end
  end
  return false
end

--- @param conversation sia.Conversation
--- @param message sia.Message
--- @param outdated boolean?
--- @return sia.PreparedMessage
local function prepare_message(conversation, message, outdated)
  local hide = false
  if message.hide then
    hide = true
  end

  local context_conf = require("sia.config").get_context_config()
  local meta
  if message.meta then
    meta = vim.deepcopy(message.meta)
  end

  local _tool_call
  if message._tool_call then
    _tool_call = vim.deepcopy(message._tool_call)
  end

  local description = message:get_description()
  outdated = outdated or message:is_outdated(conversation.id)

  local tool_calls
  if message.tool_calls then
    tool_calls = vim.deepcopy(message.tool_calls)
    for i, tool_call in ipairs(message.tool_calls) do
      if tool_call.type == "function" then
        if
          context_conf.clear_input
          and message.context
          and message.context.clear_outdated_tool_input
          and outdated
        then
          tool_calls[i] = message.context.clear_outdated_tool_input(tool_call)
        end
      end
    end
  end
  local content = get_message_content(message, outdated)
  if message.template and conversation then
    if content ~= nil and type(content) == "string" then
      local template_context = conversation:build_template_context(message.context)
      content = template.render(content, template_context)
    end
  end

  --- @type sia.PreparedMessage
  return {
    role = message.role,
    hide = hide,
    meta = meta or {},
    outdated = outdated,
    superseded = message.superseded or false,
    description = description,
    content = content,
    _tool_call = _tool_call,
    tool_calls = tool_calls,
  }
end

--- @return string
function Message:get_description()
  if self.role == "tool" and self._tool_call then
    local f = self._tool_call["function"]
    return self.role .. ": result from " .. f.name
  end
  local description = self.description
  --- @cast description string?
  if description then
    return self.role .. ": " .. description
  end

  local content = get_message_content(self, false)
  if content then
    return self.role .. ": " .. string.sub(content:gsub("\n", " "), 1, 40)
  elseif self.tool_calls then
    local name = "unknown"
    if self.tool_calls[1] and self.tool_calls[1]["function"] then
      name = self.tool_calls[1]["function"].name
    end
    return self.role .. ": calling " .. name
  end
  return self.role
end

---@type integer
local CONVERSATION_ID = 1

--- @alias sia.InstructionOption (string|sia.config.Instruction|(fun(conv: sia.Conversation?):sia.config.Instruction[]))
--- @class sia.Conversation
--- @field id integer Session unique identifier for a conversation
--- @field context sia.Context?
--- @field messages sia.Message[]
--- @field enable_supersede boolean
--- @field tools sia.config.Tool[]?
--- @field name string
--- @field model string?
--- @field temperature number?
--- @field mode sia.config.ActionMode?
--- @field todos  {buf: number?, items: sia.conversation.Todo[]}
--- @field ignore_tool_confirm boolean?
--- @field auto_confirm_tools table<string, integer>
--- @field tool_fn table<string, {allow_parallel:(fun(c: sia.Conversation, args: table):boolean)?,  message: string|(fun(args:table):string)? , action: sia.config.ToolExecute}>}?
--- @field usage_history sia.Usage[]
local Conversation = {}

Conversation.__index = Conversation
Conversation.pending_messages = {}
Conversation.pending_tools = {}

--- @param instruction sia.config.Instruction|sia.config.Instruction[]|string
--- @param args sia.Context?
--- @return boolean
function Conversation.add_pending_instruction(instruction, context)
  for _, message in ipairs(Message:new(instruction, context) or {}) do
    table.insert(Conversation.pending_messages, message)
  end
end

function Conversation.add_pending_tool(tool)
  table.insert(Conversation.pending_tools, tool)
end

--- @param action sia.config.Action
--- @param context sia.Context?
--- @return sia.Conversation
function Conversation:new(action, context)
  local obj = setmetatable({}, self)
  obj.context = context
  obj.model = action.model
  obj.temperature = action.temperature
  obj.mode = action.mode
  obj.name = ""
  obj.enable_supersede = true
  obj.id = CONVERSATION_ID
  CONVERSATION_ID = CONVERSATION_ID + 1

  obj.messages = {}
  obj.ignore_tool_confirm = action.ignore_tool_confirm
  obj.auto_confirm_tools = {}
  obj.todos = {
    buf = nil,
    items = {},
  }
  obj.usage_history = {}

  for _, instruction in ipairs(action.system or {}) do
    for _, message in ipairs(Message:new(instruction, context) or {}) do
      table.insert(obj.messages, message)
    end
  end

  for _, message in ipairs(Conversation.pending_messages) do
    table.insert(obj.messages, message)
  end
  Conversation.pending_messages = {}

  for _, instruction in ipairs(action.instructions or {}) do
    obj:add_instruction(instruction, context, { ignore_duplicates = true })
  end

  obj.tools = {}
  obj.tool_fn = {}
  for _, tool in ipairs(action.tools or {}) do
    obj:add_tool(tool)
  end
  for _, tool in ipairs(Conversation.pending_tools) do
    obj:add_tool(tool)
  end
  Conversation.pending_tools = {}

  return obj
end

--- @param tool string|sia.config.Tool
function Conversation:add_tool(tool)
  if type(tool) == "string" then
    tool = require("sia.config").options.defaults.tools.choices[tool]
  end
  if
    tool ~= nil
    and self.tool_fn[tool.name] == nil
    and (tool.is_available == nil or tool.is_available())
  then
    self.tool_fn[tool.name] = {
      message = tool.message,
      action = tool.execute,
      allow_parallel = tool.allow_parallel,
    }
    table.insert(self.tools, tool)
  end
end

function Conversation:untrack_messages()
  for _, message in ipairs(self.messages) do
    if message.context and message.context.buf and message.context.tick then
      tracker.untrack(message.context.buf)
    end
  end
end

function Conversation:clear_user_instructions()
  self:untrack_messages()

  self.messages = vim
    .iter(self.messages)
    :filter(function(m)
      return m.role == "system"
    end)
    :totable()

  if self.shell then
    self.shell:close()
    self.shell = nil
  end
end

--- Check if the new interval completely encompasses an existing interval
--- Returns true if the existing interval should be masked (new is superset of existing)
--- @param new_interval sia.Context
--- @param existing_interval sia.Context
--- @return boolean
local function should_mask_existing(new_interval, existing_interval)
  if new_interval.buf ~= existing_interval.buf then
    return false
  end

  if not new_interval.pos then
    return true
  end

  if not existing_interval.pos then
    return false
  end

  local new_start, new_end = new_interval.pos[1], new_interval.pos[2]
  local existing_start, existing_end =
    existing_interval.pos[1], existing_interval.pos[2]

  return new_start <= existing_start and existing_end <= new_end
end

--- Mark overlapping messages as superseded instead of removing them
--- Handle tool call sequences as atomic units to maintain conversation integrity
--- @param context sia.Context?
--- @param kind string?
function Conversation:_update_overlapping_messages(context, kind)
  if not context or not context.buf then
    return
  end

  local tool_call_ids_to_supersede = {}

  -- First pass: identify messages that should be marked as superseded due to overlap
  for _, message in ipairs(self.messages) do
    local old_context = message.context

    if
      old_context
      and message.kind ~= nil
      and message.kind == "context"
      and message.kind == kind
      and old_context.buf
      and message.content
      and (message.role == "user" or message.role == "tool")
    then
      if should_mask_existing(context, old_context) then
        message.superseded = true

        -- If this is a tool result being superseded, mark its tool call ID for superseding
        if message.role == "tool" and message._tool_call then
          tool_call_ids_to_supersede[message._tool_call.id] = true
        end
      end
    end
  end

  -- Second pass: also mark assistant messages whose tool calls are being superseded
  for _, message in ipairs(self.messages) do
    if message.role == "assistant" and message.tool_calls then
      for _, tool_call in ipairs(message.tool_calls) do
        if tool_call_ids_to_supersede[tool_call.id] then
          message.superseded = true
          break
        end
      end
    end
  end
end

--- @param instruction sia.config.Instruction|sia.config.Instruction[]|string
--- @param context sia.Context?
--- @param opts { ignore_duplicates: boolean?, meta: table?}?
function Conversation:add_instruction(instruction, context, opts)
  opts = opts or {}
  -- We track per-kind updates to avoid two problems:
  -- 1) Self-supersession: a single instruction can expand into multiple messages of the same `kind`.
  --    If we ran `_update_overlapping_messages` for each message, the first inserted message could
  --    be considered "existing" when processing the second, causing the second to supersede the first.
  -- 2) Redundant scans: calling the overlap logic once per kind avoids repeated O(n) passes when
  --    an instruction yields many messages.
  -- In short: run overlap updates at most once per message.kind for the current instruction batch.
  local done = {}
  for _, message in ipairs(Message:new(instruction, context) or {}) do
    if message.kind and opts.ignore_duplicates ~= true and not done[message.kind] then
      self:_update_overlapping_messages(context, message.kind)
      done[message.kind] = true
    end
    table.insert(self.messages, message)
    if opts.meta then
      message.meta = opts.meta
    end
  end
end

--- @return sia.PreparedMessage message
function Conversation:last_message()
  return prepare_message(self, self.messages[#self.messages], false)
end

--- @param name string
--- @param arguments table
--- @param opts {cancellable: sia.Cancellable?, callback:  fun(opts: sia.ToolResult?) }
--- @return string[]?
function Conversation:execute_tool(name, arguments, opts)
  if self.tool_fn[name] then
    local action = self.tool_fn[name].action
    local ok, err = pcall(action, arguments, self, opts.callback, opts.cancellable)
    if not ok then
      print(vim.inspect(err))
      opts.callback({ content = { "Tool execution failed. " }, kind = "failed" })
    end
    return
  else
    opts.callback(nil)
  end
end

--- @param opts {filter: (fun(message: sia.PreparedMessage):boolean)?}?
--- @return sia.PreparedMessage[] messages
--- @return table<integer, integer>? mappings if filter is used
function Conversation:get_messages(opts)
  opts = opts or {}

  local mappings = {}
  local return_messages = {}
  for i, message in ipairs(self:prepare_messages()) do
    if opts.filter == nil or opts.filter(message) then
      table.insert(return_messages, message)
      table.insert(mappings, i)
    end
  end

  if opts.filter then
    return return_messages, mappings
  else
    return return_messages
  end
end

--- Add usage statistics from a request/response cycle
--- @param usage sia.Usage
function Conversation:add_usage(usage)
  table.insert(self.usage_history, usage)
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

--- Build template context for rendering system prompts
--- @param context sia.Context?
--- @return table Template context
function Conversation:build_template_context(context)
  local tool_instructions = {}
  if vim.tbl_count(self.tools) > 0 then
    for _, tool in ipairs(self.tools) do
      if tool.system_prompt then
        tool_instructions[#tool_instructions + 1] =
          string.format("<%s>\n%s\n</%s>", tool.name, tool.system_prompt, tool.name)
      end
    end
  end

  return {
    filetype = (context and context.buf and vim.api.nvim_buf_is_loaded(context.buf))
        and vim.bo[context.buf].ft
      or "",
    today = os.date("%Y-%m-%d"),
    tools = self.tools,
    has_tools = #self.tools > 0,
    tool_count = #self.tools,
    has_tool = function(name)
      return self.tool_fn[name] ~= nil
    end,
  }
end

--- @return sia.PreparedMessage[]
function Conversation:prepare_messages()
  local context_config = require("sia.config").get_context_config()
  local min_keep_tool_calls = context_config.keep or 5
  local max_tool_calls = context_config.max_tool or 100
  local exclude_tool = context_config.exclude or {}

  --- @type table<string, "failed"|"outdated">
  local tool_filter = {}

  --- @type {id:string, index:integer, name:string}[]
  local tool_calls_info = {}
  for i, m in ipairs(self.messages) do
    if m._tool_call and m._tool_call.id then
      if m.kind == "failed" then
        tool_filter[m._tool_call.id] = "failed"
      elseif m._outdated_tool_call then
        tool_filter[m._tool_call.id] = "outdated"
      else
        table.insert(
          tool_calls_info,
          { id = m._tool_call.id, index = i, name = m._tool_call["function"].name }
        )
      end
    end
  end

  if min_keep_tool_calls < #tool_calls_info and #tool_calls_info > max_tool_calls then
    table.sort(tool_calls_info, function(a, b)
      return a.index > b.index
    end)

    for i, info in ipairs(tool_calls_info) do
      if i > min_keep_tool_calls and not vim.tbl_contains(exclude_tool, info.name) then
        tool_filter[info.id] = "outdated"
        self.messages[info.index]._outdated_tool_call = true
      end
    end
  end

  local last_message = self.messages[#self.messages]
  if
    last_message
    and last_message.kind == "failed"
    and last_message._tool_call
    and last_message._tool_call.id
  then
    tool_filter[last_message._tool_call.id] = nil
  end

  --- @type sia.Message[]
  local messages = vim
    .iter(self.messages)
    --- @param m sia.Message
    --- @return boolean
    :filter(function(m)
      if self.enable_supersede and m.superseded then
        return false
      end

      if not m:has_content() then
        return false
      end

      local tool_call_id = m._tool_call and m._tool_call.id
      if not tool_call_id and m.tool_calls and #m.tool_calls > 0 then
        tool_call_id = m.tool_calls[1].id
      end

      if tool_call_id and tool_filter[tool_call_id] == "failed" then
        return false
      end

      return true
    end)
    --- @param m sia.Message
    --- @return sia.PreparedMessage
    :map(function(m)
      local tool_call_id = m._tool_call and m._tool_call.id
      if not tool_call_id and m.tool_calls and #m.tool_calls > 0 then
        tool_call_id = m.tool_calls[1].id
      end
      return prepare_message(
        self,
        m,
        tool_call_id and tool_filter[tool_call_id] == "outdated"
      )
    end)
    --- @param p sia.PreparedMessage
    --- @return boolean?
    :filter(function(p)
      return (p.content and p.content ~= "") or (p.tool_calls and #p.tool_calls > 0)
    end)
    :totable()

  return messages
end

return { Message = Message, Conversation = Conversation }
