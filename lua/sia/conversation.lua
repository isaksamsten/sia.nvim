--- @class sia.Prompt
--- @field role sia.config.Role
--- @field content (string|{type:string, text: string, cache_control: {type: "ephemeral"}?})?
--- @field tool_calls sia.ToolCall[]?
--- @field tool_call_id string?

--- @alias sia.Query { model: (string|table)?, temperature: number?, prompt: sia.Prompt[], tools: sia.Tool[]?}
--- @alias sia.Tool { type: "function", function: { name: string, description: string, parameters: {type: "object", properties: table<string, sia.ToolParameter>?, required: string[]?, additionalProperties: boolean?}}}
--- @alias sia.ToolParameter { type: "number"|"string"|"array"|nil, items: { type: string }?, enum: string[]?, description: string? }

--- @class sia.Context
--- @field buf integer
--- @field win integer?
--- @field pos [integer,integer]
--- @field mode "n"|"v"?
--- @field bang boolean?
--- @field cursor integer[]?

--- @class sia.ActionContext : sia.Context
--- @field start_line integer?
--- @field end_line integer?

--- @class sia.Message
--- @field role sia.config.Role
--- @field context sia.Context?
--- @field hide boolean?
--- @field content string[]?
--- @field live_content (fun():string?)
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call sia.ToolCall?
--- @field description string?
--- @field group integer?
local Message = {}
Message.__index = Message

--- @param instruction sia.config.Instruction
--- @param context sia.Context?
--- @return string[]? content
local function make_content(instruction, context)
  --- @type string[]?
  local content
  if type(instruction.content) == "function" then
    local tmp = instruction.content(context)
    if tmp then
      if type(tmp) == "string" then
        content = vim.split(tmp, "\n", { trimempty = true })
      else
        content = tmp
      end
    end
  elseif type(instruction.content) == "table" then
    local tmp = instruction.content
    --- @cast tmp string[]
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

    content = vim.split(tmp, "\n", { trimempty = true })
  end
  if instruction.role == "tool" then
    content = content or {}
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
  if instruction.tool_calls then
    obj.tool_calls = instruction.tool_calls
  end
  if instruction._tool_call then
    obj._tool_call = instruction._tool_call
  end

  obj.hide = instruction.hide
  obj.content = make_content(instruction, context)
  obj.description = make_description(instruction, context)
  if obj.live_content == nil or type(instruction.content) ~= "function" then
    obj.context = context
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

--- @return string[]?
function Message:get_content()
  if self.content then
    return self.content
  elseif self.live_content then
    local content = self.live_content()
    if content then
      return vim.split(content, "\n")
    end
  else
    return nil
  end
end
--- @param conversation sia.Conversation?
--- @return sia.Prompt
function Message:to_prompt(conversation)
  --- @type sia.Prompt
  local prompt = { role = self.role }

  local content = self:get_content()
  if content then
    prompt.content = table.concat(content, "\n")
  end

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

--- @return boolean
function Message:is_available()
  if self.available then
    return self.available(self.context)
  end
  return true
end

--- @return table?
function Message:get_id()
  if self.id then
    return self.id(self.context)
  end
  return nil
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
  if content and #content > 0 then
    return self.role .. " " .. string.sub(content[1], 1, 40)
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
function Conversation:_update_overlapping_messages(context)
  if not context or not context.buf then
    return
  end

  local new_interval = { buf = context.buf, pos = context.pos }

  for i, message in ipairs(self.messages) do
    if
      message.context
      and message.context.buf
      and message.content
      and (message.role == "user" or message.role == "tool")
    then
      local existing_interval = { buf = message.context.buf, pos = message.context.pos }

      if should_mask_existing(new_interval, existing_interval) then
        local buf_name = vim.api.nvim_buf_get_name(existing_interval.buf)
        local file_name = vim.fn.fnamemodify(buf_name, ":t")

        if existing_interval.pos then
          local start_line, end_line = existing_interval.pos[1], existing_interval.pos[2]
          message.content = {
            string.format(
              "[SUPERSEDED] Content from %s lines %d-%d has been replaced by more comprehensive context below",
              file_name,
              start_line,
              end_line
            ),
          }
        else
          message.content = {
            string.format("[SUPERSEDED] Full content of %s has been replaced by updated context below", file_name),
          }
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
  if opts.ignore_duplicates ~= true then
    self:_update_overlapping_messages(context)
  end

  for _, message in ipairs(Message:new(instruction, context) or {}) do
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
  elseif index.kind == "example" then
    removed = table.remove(self.example_messages, index.index)
  elseif index.kind == "files" then
    removed = table.remove(self.files, index.index)
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
  -- Gather all messages (system and user)
  local all_messages = vim.iter({ self.system_messages, self.messages }):flatten():totable()

  -- First pass: determine which messages would be filtered out due to stale buffers
  local filtered = {}
  for i, m in ipairs(all_messages) do
    if m.context and not vim.api.nvim_buf_is_loaded(m.context.buf) then
      filtered[i] = true
    end
  end

  -- Second pass: if a message with tool_calls is immediately followed by a filtered _tool_call with matching id, filter both
  local to_remove = {}
  for i, m in ipairs(all_messages) do
    if m.tool_calls and all_messages[i + 1] and all_messages[i + 1]._tool_call then
      local next_msg = all_messages[i + 1]
      if filtered[i + 1] then
        -- Check if any tool_call id matches
        local ids = {}
        for _, tc in ipairs(m.tool_calls) do
          ids[tc.id] = true
        end
        if ids[next_msg._tool_call.id] then
          to_remove[i] = true
        end
      end
    end
  end

  -- Build the filtered list
  local retained = {}
  for i, m in ipairs(all_messages) do
    if not filtered[i] and not to_remove[i] then
      table.insert(retained, m)
    end
  end

  -- Map to prompts and filter as before
  local prompt = vim
    .iter(retained)
    :map(function(m)
      return m:to_prompt(self)
    end)
    :filter(function(p)
      return (p.content and p.content ~= "") or (p.tool_calls and #p.tool_calls > 0)
    end)
    :totable()

  --- @type sia.Tool[]?
  local tools = nil
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
