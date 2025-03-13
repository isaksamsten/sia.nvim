--- @alias sia.Prompt {role: sia.config.Role, content: string?, tool_calls: sia.ToolCall[]?, tool_call_id: string? }
--- @alias sia.Query { model: string?, temperature: number?, prompt: sia.Prompt, tools: sia.Tool[]?}
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
--- @field id (fun(ctx:sia.Context?):table?)?
--- @field role sia.config.Role
--- @field hide boolean?
--- @field content (string[]|string|(fun(ctx:sia.Context?):string))?
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call sia.ToolCall?
--- @field persistent boolean?
--- @field available (fun(ctx: sia.Context?):boolean)?
--- @field description ((fun(ctx: sia.Context?):string)|string)?
--- @field context sia.Context?
local Message = {}
Message.__index = Message

--- @param instruction sia.config.Instruction
--- @param args sia.Context?
--- @return sia.Message
function Message:from_table(instruction, args)
  local obj = setmetatable({}, self)
  obj.id = instruction.id
  obj.role = instruction.role
  obj.hide = instruction.hide
  obj.available = instruction.available
  obj.content = instruction.content
  obj.description = instruction.description
  obj.persistent = instruction.persistent
  if instruction.tool_calls then
    obj.tool_calls = instruction.tool_calls
  end
  if instruction._tool_call then
    obj._tool_call = instruction._tool_call
  end
  if args then
    obj.context = {
      buf = args.buf,
      win = args.win,
      mode = args.mode,
      bang = args.bang,
      cursor = args.cursor,
      pos = args.pos,
    }
  end
  return obj
end

--- Create a new message from a stored instruction
--- @param str string|string[]
--- @param args sia.Context?
--- @return sia.Message[]?
function Message:from_string(str, args)
  if type(str) == "string" then
    local instruction = require("sia.config").options.instructions[str]
    if not instruction then
      instruction = require("sia.builtin")[str]
    end
    if instruction then
      if vim.islist(instruction) then
        local messages = {}
        for _, step in ipairs(instruction) do
          table.insert(messages, Message:from_table(step, args))
        end
        return messages
      end
      return { Message:from_table(instruction, args) }
    end
  end
end

--- Create a new message from an Instruction or a stored instruction.
--- @param instruction sia.config.Instruction|string|sia.config.Instruction[]
--- @param args sia.Context?
--- @return sia.Message[]?
function Message:new(instruction, args)
  if type(instruction) == "string" then
    return Message:from_string(instruction, args)
  elseif vim.islist(instruction) then
    local messages = {}
    for _, step in ipairs(instruction) do
      table.insert(messages, Message:from_table(step, args))
    end
    return messages
  else
    return { Message:from_table(instruction, args) }
  end
end

--- @return sia.Prompt
function Message:to_prompt()
  local prompt = { role = self.role }
  if self.content then
    if type(self.content) == "function" then
      prompt.content = self.content(self.context)
    elseif type(self.content) == "table" then
      local content = self.content
      --- @cast content [string]
      prompt.content = table.concat(content, "\n")
    else
      prompt.content = self.content
    end
  end
  if self.tool_calls then
    prompt.tool_calls = self.tool_calls
  end
  if self._tool_call then
    prompt.tool_call_id = self._tool_call.id
  end
  return prompt
end

--- @return boolean
function Message:is_context()
  return (self.role == "user" and self.persistent == true and self:is_available()) or self.role == "tool"
end

function Message:is_shown()
  return not (self.hide == true or self.persistent == true or self.role == "system" or self.role == "tool")
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

--- @return string[]? content
function Message:get_content()
  --- @type string[]?
  local content
  if type(self.content) == "function" then
    local tmp = self.content(self.context)
    if tmp then
      content = vim.split(tmp, "\n", { trimempty = true })
    end
  elseif type(self.content) == "table" then
    local tmp = self.content
    --- @cast tmp string[]
    content = tmp
  else
    local tmp = self.content
    --- @cast tmp string
    content = vim.split(tmp, "\n", { trimempty = true })
  end
  return content
end

--- @return string
function Message:get_description()
  if self.role == "tool" then
    local f = self._tool_call["function"]
    return "Tool: " .. f.name .. "(" .. f.arguments .. ")"
  end
  if type(self.description) == "function" then
    return self.description(self.context)
  else
    local description = self.description
    --- @cast description string?
    if description then
      return description
    end
    local content = self:get_content()
    if content and #content > 0 then
      return self.role .. " " .. string.sub(content[1], 1, 40)
    end
    return self.role
  end
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
    :flatten()
    :totable()
end
--- @alias sia.InstructionOption (string|sia.config.Instruction|(fun(conv: sia.Conversation?):sia.config.Instruction[]))
--- @class sia.Conversation
--- @field instructions {instruction: sia.InstructionOption, context: sia.Context?}[]
--- @field indexed_instructions table<integer, {instruction: sia.InstructionOption, context: sia.Context?}>
--- @field reminder { instruction: (string|sia.config.Instruction)?, context: sia.Context? }
--- @field tools sia.config.Tool[]?
--- @field model string?
--- @field files string[]
--- @field temperature number?
--- @field mode sia.config.ActionMode?
--- @field context sia.Context
--- @field tool_fn table<string, fun(arguments: table, conversation: sia.Conversation, callback: fun(content: string[]?, confirmation: { description: string[]}?):nil)>?
local Conversation = {}

Conversation.__index = Conversation
Conversation._buffers = {}

--- @param action sia.config.Action
--- @param args sia.ActionContext
--- @return sia.Conversation
function Conversation:new(action, args)
  local obj = setmetatable({}, self)
  obj.model = action.model
  obj.temperature = action.temperature
  obj.mode = action.mode
  obj.files = require("sia.utils").get_global_files() or {}
  require("sia.utils").clear_global_files()
  obj.context = {
    buf = args.buf,
    win = args.win,
    mode = args.mode,
    bang = args.bang,
    pos = args.pos,
    -- pos = { args.start_line, args.end_line },
    cursor = args.cursor,
  }
  obj.instructions = {}
  for _, instruction in ipairs(action.instructions or {}) do
    --- @diagnostic disable-next-line: param-type-mismatch
    table.insert(obj.instructions, { instruction = vim.deepcopy(instruction), context = obj.context })
  end
  obj.indexed_instructions = {}
  if action.reminder then
    --- @diagnostic disable-next-line: param-type-mismatch
    obj.reminder = { instruction = vim.deepcopy(action.reminder), context = obj.context }
  end
  obj.tools = action.tools or require("sia.config").options.defaults.tools.default
  obj.tool_fn = {}
  for _, tool in ipairs(obj.tools or {}) do
    obj.tool_fn[tool.name] = tool.execute
  end

  return obj
end

--- @param files string[]
function Conversation:add_files(files)
  for _, file in ipairs(files) do
    if not vim.tbl_contains(self.files, file) then
      self.files[#self.files + 1] = file
    end
  end
end

function Conversation:add_file(file)
  if not vim.tbl_contains(self.files, file) then
    self.files[#self.files + 1] = file
  end
end

--- @param patterns string[]
function Conversation:remove_files(patterns)
  --- @type string[]
  local regexes = {}
  for i, pattern in ipairs(patterns) do
    regexes[i] = vim.fn.glob2regpat(pattern)
  end

  --- @type integer[]
  local to_remove = {}
  for i, file in ipairs(self.files) do
    for _, regex in ipairs(regexes) do
      if vim.fn.match(file, regex) ~= -1 then
        table.insert(to_remove, i)
        break
      end
    end
  end

  for i = #to_remove, 1, -1 do
    table.remove(self.files, to_remove[i])
  end
end
--- @param id table?
--- @return boolean
function Conversation:contains_message(id)
  if id then
    for _, other in ipairs(self.instructions) do
      local messages = self:_to_message(other)
      for _, message in ipairs(messages or {}) do
        local message_id = message:get_id()
        if message_id and vim.deep_equal(message_id, id) then
          return true
        end
      end
    end
  end
  return false
end

--- @param instruction sia.config.Instruction|string
--- @param args sia.Context?
--- @param index integer?
--- @return boolean
function Conversation:add_instruction(instruction, args, index)
  local tmp_messages = Message:new(instruction, args)
  local contains = false
  for _, message in ipairs(tmp_messages or {}) do
    local message_id = message:get_id()
    if self:contains_message(message_id) then
      contains = true
    end
  end
  if not contains then
    local instruction_option = { instruction = instruction, context = args, index = index }
    table.insert(self.instructions, instruction_option)
    if index then
      self.indexed_instructions[index] = instruction_option
    end
    return true
  end

  return false
end

--- @param index integer
--- @return sia.Message[]?
function Conversation:get_indexed_message(index)
  return self:_to_message(self.indexed_instructions[index])
end

--- @return sia.Message message
function Conversation:last_message()
  local instruction = self.instructions[#self.instructions]
  local messages = self:_to_message(instruction)
  if not messages then
    error("No messages found")
  end
  return messages[#messages]
end

--- @param filter (fun(message: sia.Message):boolean)?
--- @return string[] description
--- @return integer[] mapping
function Conversation:get_message_mappings(filter)
  local descriptions = {}
  local mappings = {}
  for i, instruction in ipairs(self.instructions) do
    local description = {}
    local tmp_messages = self:_to_message(instruction)
    for _, message in ipairs(tmp_messages or {}) do
      if filter == nil or filter(message) then
        table.insert(description, message:get_description())
      end
    end
    if #description > 0 then
      mappings[#mappings + 1] = i
      descriptions[#descriptions + 1] = table.concat(description, ", ")
    end
  end
  return descriptions, mappings
end

function Conversation:remove_instruction(index)
  local removed = table.remove(self.instructions, index)
  if removed and removed.index then
    self.indexed_instructions[removed.index] = nil
  end
end

--- @param content string[]
--- @return boolean success
function Conversation:update_instruction(index, content)
  if not self:is_instruction_editable(index) then
    return false
  end
  local instruction_option = self.instructions[index]
  if instruction_option then
    instruction_option.instruction.content = content
    if instruction_option.index then
      self.indexed_instructions[instruction_option.index].instruction.content = content
    end
  end
end

function Conversation:is_instruction_editable(index)
  local instruction_option = self.instructions[index]
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

function Conversation:get_context_messages()
  local messages = {}
  for _, instruction in ipairs(self.instructions) do
    local tmp_messages = self:_to_message(instruction)
    for _, message in ipairs(tmp_messages or {}) do
      if message:is_context() then
        table.insert(messages, message)
      end
    end
  end
  return messages
end

--- @param name string
--- @param arguments table
--- @param strategy sia.Strategy
--- @param callback  fun(content: string[]?):nil
--- @return string[]?
function Conversation:execute_tool(name, arguments, strategy, callback)
  if self.tool_fn[name] then
    return self.tool_fn[name](arguments, strategy.conversation, callback)
  end
end

--- @param opts {filter: (fun(message: sia.Message):boolean)?, mapping: boolean?}?
--- @return sia.Message[] messages
--- @return integer[]? mappings if mapping is set to true
function Conversation:get_messages(opts)
  opts = opts or {}
  local mappings = {}
  local messages = {}
  for i, instrop in ipairs(self.instructions) do
    local message = self:_to_message(instrop)
    if message then
      for _, m in ipairs(message) do
        if m:is_available() and (opts.filter == nil or opts.filter(m)) then
          table.insert(messages, m)
          table.insert(mappings, i)
        end
      end
    end
  end

  if opts.mapping then
    return messages, mappings
  else
    return messages
  end
end

--- @param instruction_context {instruction: sia.InstructionOption, context: sia.Context?}?
--- @return sia.Message[]?
function Conversation:_to_message(instruction_context)
  if instruction_context == nil then
    return nil
  end

  local instruction
  if type(instruction_context.instruction) == "function" then
    instruction = instruction_context.instruction(self)
  else
    instruction = instruction_context.instruction
  end
  --- @cast instruction sia.config.Instruction|string|sia.config.Instruction[]
  return Message:new(instruction, instruction_context.context)
end

function Conversation:unpack_instruction(instruction)
  if type(instruction) == "function" then
    return instruction(self)
  else
    return instruction
  end
end

--- @return sia.Query
function Conversation:to_query()
  local prompt = vim
    .iter(self.instructions)
    :map(function(instruction_context)
      return self:_to_message(instruction_context)
    end)
    :flatten()
    :filter(function(m)
      return m:is_available()
    end)
    :map(function(m)
      return m:to_prompt()
    end)
    :filter(function(p)
      return (p.content and p.content ~= "") or (p.tool_calls and #p.tool_calls > 0)
    end)
    :totable()

  if self.reminder then
    -- local reminders = Message:new(self:unpack_instruction(self.reminder.instruction), self.reminder.context)
    --- @diagnostic disable-next-line param-type-mismatch
    local reminders = self:_to_message(self.reminder)
    for _, reminder in ipairs(reminders or {}) do
      if reminder:is_available() then
        if #prompt == 0 or prompt[#prompt].role ~= "user" then
          table.insert(prompt, #prompt + 1, reminder:to_prompt())
        else
          table.insert(prompt, #prompt, reminder:to_prompt())
        end
      end
    end
  end

  --- @type sia.Tool[]?
  local tools = nil
  if self.tools then
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

  --- @type sia.Query
  return {
    model = self.model,
    temperature = self.temperature,
    prompt = prompt,
    tools = tools,
  }
end

return { Message = Message, Conversation = Conversation }
