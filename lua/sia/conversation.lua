--- @class sia.Prompt
--- @field role sia.config.Role
--- @field content (string|{type:string, text: string, cache_control: {type: "ephemeral"}?})?
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
--- @field changedtick integer?

--- @class sia.ActionContext : sia.Context
--- @field start_line integer?
--- @field end_line integer?

--- @class sia.Message
--- @field role sia.config.Role
--- @field context sia.Context?
--- @field hide boolean?
--- @field kind string?
--- @field content string?
--- @field content_gen fun(context: sia.Context?):string
--- @field live_content (fun():string?)
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call sia.ToolCall?
--- @field description string?
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
local function make_content(instruction, context)
  --- @type string?
  local content
  if type(instruction.content) == "function" then
    content = generate_content(instruction.content, context)
  elseif type(instruction.content) == "table" then
    local tmp = instruction.content
    --- @cast tmp string[]
    content = table.concat(tmp, "\n")
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

--- @return string?
function Message:get_content()
  if self.content then
    local has_changed = false
    if self.context and self.kind ~= nil then
      if
        self.context.buf
        and vim.api.nvim_buf_is_loaded(self.context.buf)
        and self.context.changedtick ~= vim.b[self.context.buf].changedtick
      then
        has_changed = true
      elseif self.content_gen then
        local new_content = generate_content(self.content_gen, self.context)
        if self.content ~= new_content then
          has_changed = true
        else
          has_changed = false
        end
      end
    end
    if has_changed then
      return "[OUTDATED CONTENT - IGNORE THIS MESSAGE]\n\nThe content below is stale. The file has been modified since this was captured.\nIMPORTANT: Use the 'read' tool to get the current content instead.\n\n"
        .. (self.content or "")
    end
    return self.content
  elseif self.live_content then
    return self.live_content()
  else
    return nil
  end
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
      prompt.content = string.gsub(prompt.content, "%{%{([%w_]+)%}%}", {
        tool_instructions = tool_prompt,
      })
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
    return "Calling the tool " .. f.name
  end
  local description = self.description
  --- @cast description string?
  if description then
    return description
  end

  local content = self:get_content()
  if content then
    return self.role .. " " .. string.sub(content, 1, 40)
  elseif self.tool_calls then
    return self.role .. " calling tools..."
  end
  return self.role
end

--- @alias sia.InstructionOption (string|sia.config.Instruction|(fun(conv: sia.Conversation?):sia.config.Instruction[]))
--- @class sia.Conversation
--- @field context sia.Context?
--- @field system_messages sia.Message[]
--- @field messages sia.Message[]
--- @field indexed_instructions table<integer, {instruction: sia.InstructionOption, context: sia.Context?}>
--- @field tools sia.config.Tool[]?
--- @field model string?
--- @field files { path: string, pos: [integer, integer]?}[]
--- @field temperature number?
--- @field mode sia.config.ActionMode?
--- @field ignore_tool_confirm boolean?
--- @field tool_fn table<string, {is_interactive:(fun(c: sia.Conversation, args: table):boolean)?,  message: string|(fun(args:table):string)? , action: fun(arguments: table, conversation: sia.Conversation, callback: fun(opts: sia.ToolResult):nil)}>}?
local Conversation = {}

Conversation.__index = Conversation
Conversation.pending_messages = {}
Conversation.pending_files = {}
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

  obj.indexed_instructions = {}
  obj.system_messages = {}
  obj.messages = {}
  obj.ignore_tool_confirm = action.ignore_tool_confirm

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
  if tool ~= nil and self.tool_fn[tool.name] == nil then
    self.tool_fn[tool.name] = { message = tool.message, action = tool.execute, is_interactive = tool.is_interactive }
    table.insert(self.tools, tool)
  end
end

--- @param needle { path: string, pos: [integer, integer]?}
function Conversation:_find_file(needle)
  for _, haystack in ipairs(self.files) do
    if haystack.path == needle.path and vim.deep_equal(haystack, needle) then
      return true
    end
  end
end

function Conversation:clear_user_instructions()
  self.messages = {}
end

--- Check if the new interval completely encompasses an existing interval
--- Returns true if the existing interval should be masked (new is superset of existing)
--- @param new_interval sia.Context
--- @param existing_interval sia.Context
--- @return boolean
local function should_mask_existing(new_interval, existing_interval)
  -- Different buffers don't overlap
  if new_interval.buf ~= existing_interval.buf then
    return false
  end

  -- If new interval has no pos (entire file), mask any existing content for this buffer
  if not new_interval.pos then
    return true
  end

  -- If existing interval has no pos (entire file), don't mask it unless new is also entire file
  if not existing_interval.pos then
    return false
  end

  local new_start, new_end = new_interval.pos[1], new_interval.pos[2]
  local existing_start, existing_end = existing_interval.pos[1], existing_interval.pos[2]

  -- Mask existing if new completely encompasses it (new is superset of existing)
  return new_start <= existing_start and existing_end <= new_end
end

--- Update overlapping messages with replacement content
--- @param context sia.Context?
--- @param kind string?
function Conversation:_update_overlapping_messages(context, kind)
  if not context or not context.buf then
    return
  end

  for i, message in ipairs(self.messages) do
    local old_context = message.context
    if
      old_context
      and message.kind ~= nil
      and message.kind == kind
      and old_context.buf
      and message.content
      and (message.role == "user" or message.role == "tool")
    then
      if should_mask_existing(context, old_context) then
        local buf_name = vim.api.nvim_buf_get_name(old_context.buf)
        local file_name = vim.fn.fnamemodify(buf_name, ":t")

        -- This context is no longer relevant...
        message.content_gen = nil
        message.context = nil
        if old_context.pos then
          local start_line, end_line = old_context.pos[1], old_context.pos[2]
          message.content = string.format(
            "[CONTENT_SUPERSEDED]\nFile: %s (lines %d-%d)\nStatus: This content has been replaced by updated context\nAction: Ignore this message and use the newer content provided later",
            file_name,
            start_line,
            end_line
          )
        else
          message.content = string.format(
            "[CONTENT_SUPERSEDED]\nFile: %s\nStatus: Full content has been replaced by updated context\nAction: Ignore this message and use the newer content provided later",
            file_name
          )
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

--- @param index {kind:string, index:number}
function Conversation:remove_instruction(index)
  local removed

  if index.kind == "system" then
    removed = table.remove(self.system_messages, index.index)
  elseif index.kind == "user" then
    removed = table.remove(self.messages, index.index)
  else
    removed = nil
  end
  if removed and removed.index then
    self.indexed_instructions[removed.index] = nil
  end
end

--- @param index {kind:string, index:number}
--- @param content string[]
--- @return boolean success
function Conversation:update_instruction(index, content)
  if not self:is_instruction_editable(index) then
    return false
  end
  local instruction_option = self:get_instruction(index)
  if instruction_option then
    instruction_option.instruction.content = content
    if instruction_option.index then
      self.indexed_instructions[instruction_option.index].instruction.content = content
    end
    return true
  end
end

--- @param index {kind: string, index: integer}
function Conversation:get_instruction(index)
  if index.kind == "system" then
    return self.system_messages[index.index]
  elseif index.kind == "example" then
    return self.example_messages[index.index]
  elseif index.kind == "files" then
    return self.files[index.index]
  elseif index.kind == "user" then
    return self.messages[index.index]
  else
    return nil
  end
end

--- @param index {kind: string, index: integer}
function Conversation:is_instruction_editable(index)
  local instruction_option = self:get_instruction(index)
  if instruction_option == nil then
    return false
  end
  if type(instruction_option.instruction) == "function" or type(instruction_option.instruction) == "string" then
    return false
  end

  --- @diagnostic disable-next-line param-type-mismatch
  if vim.islist(instruction_option.instruction) then
    return false
  end

  if type(instruction_option.instruction.content) == "function" then
    return false
  end

  return true
end

--- @param name string
--- @param arguments table
--- @param strategy sia.Strategy
--- @param callback  fun(opts: sia.ToolResult?):nil
--- @return string[]?
function Conversation:execute_tool(name, arguments, strategy, callback)
  if self.tool_fn[name] then
    local ok, err = pcall(self.tool_fn[name].action, arguments, strategy.conversation, callback)
    if not ok then
      print(vim.inspect(err))
      callback({ content = { "Tool execution failed. " }, cancel = true })
    end
    return
  else
    callback(nil)
  end
end

--- @param opts {filter: (fun(message: sia.Message):boolean)?, mapping: boolean?, kind: string?}?
--- @return sia.Message[] messages
--- @return {kind: string, index: integer}[]? mappings if mapping is set to true
function Conversation:get_messages(opts)
  opts = opts or {}

  local message_kinds = {
    { kind = "system", messages = self.system_messages },
    { kind = "user", messages = self.messages },
  }
  local mappings = {}
  local return_messages = {}
  for _, message_kind in ipairs(message_kinds) do
    if opts.kind == nil or opts.kind == message_kind.kind then
      for i, message in ipairs(message_kind.messages) do
        if opts.filter == nil or opts.filter(message) then
          table.insert(return_messages, message)
          table.insert(mappings, { kind = message_kind.kind, index = i })
        end
      end
    end
  end

  if opts.mapping then
    return return_messages, mappings
  else
    return return_messages
  end
end

function Conversation:unpack_instruction(instruction)
  if type(instruction) == "function" then
    return instruction(self)
  else
    return instruction
  end
end

--- @param kind string?
--- @return sia.Query
function Conversation:to_query(kind)
  local prompt = vim
    .iter({ self.system_messages, self.messages })
    :flatten()
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
