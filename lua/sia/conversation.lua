local tracker = require("sia.tracker")

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

--- @alias sia.Query { model: (string|table)?, temperature: number?, prompt: sia.Prompt[], tools: sia.Tool[]?}
--- @alias sia.Tool { type: "function", function: { name: string, description: string, parameters: {type: "object", properties: table<string, sia.ToolParameter>?, required: string[]?, additionalProperties: boolean?}}}
--- @alias sia.ToolParameter { type: "number"|"string"|"array"|nil, items: { type: string }?, enum: string[]?, description: string? }

--- @class sia.Context
--- @field buf integer?
--- @field win integer?
--- @field pos [integer,integer]?
--- @field mode "n"|"v"?
--- @field bang boolean?
--- @field cursor integer[]?
--- @field tick integer?
--- @field outdated_message string?

--- @class sia.ActionContext : sia.Context
--- @field start_line integer?
--- @field end_line integer?

--- @class sia.Message
--- @field role sia.config.Role
--- @field context sia.Context?
--- @field hide boolean?
--- @field kind string?
--- @field content (string|sia.InstructionContent[])?
--- @field content_gen fun(context: sia.Context?):string
--- @field live_content (fun():string?)
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call sia.ToolCall?
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
  -- This is a normal text content
  elseif type(instruction.content) == "table" and type(instruction.content[1]) == "string" then
    local tmp = instruction.content
    --- @cast tmp string[]
    content = table.concat(tmp, "\n")
  elseif type(instruction.content) == "table" then
    local tmp = instruction.content
    --- @cast tmp sia.InstructionContent[]
    content = tmp
  elseif instruction.content ~= nil and type(instruction.content) == "string" then
    local tmp = instruction.content
    --- @cast tmp string
    if context and vim.api.nvim_buf_is_loaded(context.buf) then
      tmp = string.gsub(tmp, "%{%{(%w+)%}%}", {
        filetype = vim.bo[context.buf].ft,
        today = os.date("%Y-%m-%d"),
      })
    end

    content = tmp
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

--- @return (string|sia.InstructionContent[])?
function Message:get_content()
  if self.content then
    if self:is_outdated() then
      return string.format("System Note: History pruned. %s", self.context.outdated_message or "")
    end
    return self.content
  elseif self.live_content then
    return self.live_content()
  else
    return nil
  end
end

--- Check if this message is outdated (has nil content when it should have content)
--- @return boolean
function Message:is_outdated()
  if self.live_content then
    return false
  end

  if
    self.context
    and self.context.tick
    and self.kind ~= nil
    and (self.role == "tool" or (self.content and self.role ~= "assistant"))
  then
    if vim.api.nvim_buf_is_loaded(self.context.buf) then
      return self.context.tick ~= tracker.user_tick(self.context.buf)
    else
      return true
    end
  end
  return false
end

--- @param conversation sia.Conversation?
--- @return sia.Prompt
function Message:to_prompt(conversation)
  --- @type sia.Prompt
  local prompt = { role = self.role, content = self:get_content() }

  if self.tool_calls then
    prompt.tool_calls = {}
    for _, tool_call in ipairs(self.tool_calls) do
      if tool_call.type == "function" then
        table.insert(prompt.tool_calls, { id = tool_call.id, type = "function", ["function"] = tool_call["function"] })
      end
    end
  end
  if self._tool_call then
    prompt.tool_call_id = self._tool_call.id
  end
  if self.role == "system" and conversation then
    --- @type string[]
    local tool_instructions = {}
    if vim.tbl_count(conversation.tools) > 0 then
      for _, tool in ipairs(conversation.tools) do
        if tool.system_prompt then
          tool_instructions[#tool_instructions + 1] =
            string.format("<%s>\n%s\n</%s>", tool.name, tool.system_prompt, tool.name)
        end
      end
    end

    if #tool_instructions > 0 then
      local tool_prompt = table.concat(tool_instructions, "\n")
      if prompt.content ~= nil then
        prompt.content = string.gsub(prompt.content, "%{%{([%w_]+)%}%}", {
          tool_instructions = tool_prompt,
        })
      end
    end
  end
  return prompt
end

function Message:is_shown()
  return not (self.hide == true or self.role == "system" or self.role == "tool")
end

--- @param messages sia.Message[]?
--- @return string[]? content
function Message.merge_content(messages)
  if messages == nil then
    return nil
  end

  return vim
    .iter(messages)
    :map(function(m)
      return m:get_content()
    end)
    :filter(function(content)
      return content ~= nil
    end)
    :flatten()
    :totable()
end

--- @return string
function Message:get_description()
  if self.role == "tool" then
    local f = self._tool_call["function"]
    return self.role .. ": result from " .. f.name
  end
  local description = self.description
  --- @cast description string?
  if description then
    return self.role .. ": " .. description
  end

  local content = self:get_content()
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

--- @alias sia.InstructionOption (string|sia.config.Instruction|(fun(conv: sia.Conversation?):sia.config.Instruction[]))
--- @class sia.Conversation
--- @field context sia.Context?
--- @field messages sia.Message[]
--- @field tools sia.config.Tool[]?
--- @field model string?
--- @field temperature number?
--- @field mode sia.config.ActionMode?
--- @field ignore_tool_confirm boolean?
--- @field auto_confirm_tools table<string, integer>
--- @field tool_fn table<string, {allow_parallel:(fun(c: sia.Conversation, args: table):boolean)?,  message: string|(fun(args:table):string)? , action: sia.config.ToolExecute}>}?
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

  obj.messages = {}
  obj.ignore_tool_confirm = action.ignore_tool_confirm
  obj.auto_confirm_tools = {}

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
  if tool ~= nil and self.tool_fn[tool.name] == nil and (tool.is_available == nil or tool.is_available()) then
    self.tool_fn[tool.name] = { message = tool.message, action = tool.execute, allow_parallel = tool.allow_parallel }
    table.insert(self.tools, tool)
  end
end

function Conversation:clear_user_instructions()
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
  local existing_start, existing_end = existing_interval.pos[1], existing_interval.pos[2]

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
--- @param opts { ignore_duplicates: boolean?}?
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
  end
end

--- @return sia.Message message
function Conversation:last_message()
  return self.messages[#self.messages]
end

--- @param index integer
--- @return sia.Message?
function Conversation:remove_instruction(index)
  return table.remove(self.messages, index)
end

--- @param name string
--- @param arguments table
--- @param opts {cancellable: sia.Cancellable?, callback:  fun(opts: sia.ToolResult?) }
--- @return string[]?
function Conversation:execute_tool(name, arguments, opts)
  if self.tool_fn[name] then
    local ok, err = pcall(self.tool_fn[name].action, arguments, self, opts.callback, opts.cancellable)
    if not ok then
      print(vim.inspect(err))
      opts.callback({ content = { "Tool execution failed. " } })
    end
    return
  else
    opts.callback(nil)
  end
end

--- @param opts {filter: (fun(message: sia.Message):boolean)?, mapping: boolean?}?
--- @return sia.Message[] messages
--- @return table<integer, integer>? mappings if mapping is set to true
function Conversation:get_messages(opts)
  opts = opts or {}

  local mappings = {}
  local return_messages = {}
  for i, message in ipairs(self.messages) do
    if opts.filter == nil or opts.filter(message) then
      table.insert(return_messages, message)
      table.insert(mappings, i)
    end
  end

  if opts.mapping then
    return return_messages, mappings
  else
    return return_messages
  end
end

--- @param kind string?
--- @return sia.Query
function Conversation:to_query(kind)
  local prompt = vim
    .iter(self.messages)
    --- @param m sia.Message
    --- @return boolean
    :filter(function(m)
      if m.superseded then
        return false
      end

      return true
    end)
    --- @param m sia.Message
    --- @return sia.Prompt
    :map(function(m)
      return m:to_prompt(self)
    end)
    --- @param p sia.Prompt
    --- @return boolean?
    :filter(function(p)
      return (p.content and p.content ~= "") or (p.tool_calls and #p.tool_calls > 0)
    end)
    :totable()

  --- @type sia.Tool[]?
  local tools = nil
  -- We need to set tools to nil if there are no tools
  -- so that unsupported models doesn't get confused.
  if self.tools and #self.tools > 0 then
    tools = {}
    for _, tool in ipairs(self.tools) do
      tools[#tools + 1] = {
        type = "function",
        ["function"] = {
          name = tool.name,
          description = tool.description,
          parameters = {
            type = "object",
            properties = tool.parameters,
            required = tool.required,
            additionalProperties = false,
          },
        },
      }
    end
  end

  return {
    model = self.model,
    temperature = self.temperature,
    prompt = prompt,
    tools = tools,
  }
end

return { Message = Message, Conversation = Conversation }
