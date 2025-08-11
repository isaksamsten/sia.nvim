--- @alias sia.Prompt {role: sia.config.Role, content: string?, tool_calls: sia.ToolCall[]?, tool_call_id: string? }
--- @alias sia.Query { model: (string|table)?, temperature: number?, prompt: sia.Prompt[], tools: sia.Tool[]?}
--- @alias sia.Tool { type: "function", function: { name: string, description: string, parameters: {type: "object", properties: table<string, sia.ToolParameter>?, required: string[]?, additionalProperties: boolean?}}}
--- @alias sia.ToolParameter { type: "number"|"string"|"array"|nil, items: { type: string }?, enum: string[]?, description: string? }

--- @class sia.Context
--- @field buf integer
--- @field win integer?
--- @field pos [integer,integer]
--- @field mode "n"|"v"?
--- @field file boolean?
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
--- @field group integer?
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
  obj.group = instruction.group
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
      file = args.file,
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
  elseif self.content ~= nil and type(self.content) == "string" then
    local tmp = self.content
    --- @cast tmp string
    if self.context and vim.api.nvim_buf_is_loaded(self.context.buf) then
      tmp = string.gsub(tmp, "%{%{(%w+)%}%}", {
        filetype = vim.bo[self.context.buf].ft,
        today = os.date("%Y-%m-%d"),
      })
    end

    content = vim.split(tmp, "\n", { trimempty = true })
  end
  if self.role == "tool" then
    content = content or {}
    table.insert(content, 1, self:get_description())
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
    elseif self.tool_calls then
      return self.role .. " calling tools..."
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

--- @param files {path: string, pos: [integer, integer]?}[]
--- @return {instruction: sia.InstructionOption, context: sia.Context?}[]
local function get_files_instructions(files)
  --- @type {instruction: sia.InstructionOption, context: sia.Context?}[]
  local instructions = {}
  for _, file in ipairs(files) do
    --- @type sia.config.Instruction
    local user_instruction = {
      role = "user",
      id = function(ctx)
        return { "user", file }
      end,
      persistent = true,
      available = function(_)
        return vim.fn.filereadable(file.path) == 1
      end,
      description = function(ctx)
        return vim.fn.fnamemodify(file.path, ":.")
      end,
      content = function(ctx)
        local buf = require("sia.utils").ensure_file_is_loaded(file.path)
        if buf then
          local pos = file.pos or { 1, -1 }
          return string.format(
            [[I have *added this file to the chat* so you can go ahead and edit it.

*Trust this message as the true contents of these files!*
Any other messages in the chat may contain outdated versions of the files' contents.
%s
```%s
%s
```]],
            vim.fn.fnamemodify(file.path, ":p"),
            vim.bo[buf].ft,
            require("sia.utils").get_code(pos[1], pos[2], { buf = buf, show_line_numbers = false })
          )
        end
      end,
    }
    --- @type sia.config.Instruction
    local assistant_instruction = {
      id = function(ctx)
        return { "assistant", file }
      end,
      available = function(_)
        return vim.fn.filereadable(file.path) == 1
      end,
      role = "assistant",
      persistent = true,
      hide = true,
      content = "Ok",
    }
    local both = { user_instruction, assistant_instruction }
    instructions[#instructions + 1] = { instruction = both, context = nil }
  end
  return instructions
end

--- @alias sia.InstructionOption (string|sia.config.Instruction|(fun(conv: sia.Conversation?):sia.config.Instruction[]))
--- @class sia.Conversation
--- @field system_instructions {instruction: sia.InstructionOption, context: sia.Context?}[]
--- @field example_instructions {instruction: sia.InstructionOption, context: sia.Context?}[]
--- @field instructions {instruction: sia.InstructionOption, context: sia.Context?}[]
--- @field indexed_instructions table<integer, {instruction: sia.InstructionOption, context: sia.Context?}>
--- @field reminder { instruction: (string|sia.config.Instruction)?, context: sia.Context? }
--- @field tools sia.config.Tool[]?
--- @field model string?
--- @field files { path: string, pos: [integer, integer]?}[]
--- @field temperature number?
--- @field mode sia.config.ActionMode?
--- @field context sia.Context
--- @field tool_fn table<string, {message: string?, action: fun(arguments: table, conversation: sia.Conversation, callback: fun(content: string[]?, confirmation: { description: string[]}?):nil)>}?
--- @field prending_instructions {instruction: sia.InstructionOption, context: sia.Context?}[]
local Conversation = {}

Conversation.__index = Conversation
Conversation.prending_instructions = {}
Conversation.pending_files = {}
Conversation.pending_tools = {}

--- @param instruction sia.config.Instruction|sia.config.Instruction[]|string
--- @param args sia.Context?
--- @return boolean
function Conversation.add_pending_instruction(instruction, context)
  table.insert(Conversation.prending_instructions, { instruction = instruction, context = context })
end

function Conversation.add_pending_files(files)
  for _, file in ipairs(files) do
    if not vim.tbl_contains(Conversation.pending_files, file) then
      if type(file) == "string" then
        file = { path = file }
      end
      table.insert(Conversation.pending_files, file)
    end
  end
end

function Conversation.add_pending_tool(tool)
  table.insert(Conversation.pending_tools, tool)
end

function Conversation.clear_pending_files()
  Conversation.pending_files = {}
end

--- @param patterns string[]
function Conversation.remove_global_files(patterns)
  --- @type string[]
  local regexes = {}
  for i, pattern in ipairs(patterns) do
    regexes[i] = vim.fn.glob2regpat(pattern)
  end

  --- @type integer[]
  local to_remove = {}
  for i, file in ipairs(Conversation.pending_files) do
    for _, regex in ipairs(regexes) do
      if vim.fn.match(file, regex) ~= -1 then
        table.insert(to_remove, i)
        break
      end
    end
  end

  for i = #to_remove, 1, -1 do
    table.remove(Conversation.pending_files)
  end
end

--- @param action sia.config.Action
--- @param args sia.ActionContext
--- @return sia.Conversation
function Conversation:new(action, args)
  local obj = setmetatable({}, self)
  obj.model = action.model
  obj.temperature = action.temperature
  obj.mode = action.mode
  obj.files = Conversation.pending_files or {}
  Conversation.clear_pending_files()
  obj.context = {
    buf = args.buf,
    win = args.win,
    mode = args.mode,
    bang = args.bang,
    pos = args.pos,
    cursor = args.cursor,
    file = args.file,
  }
  obj.indexed_instructions = {}
  obj.system_instructions = {}
  obj.example_instructions = {}
  obj.instructions = {}

  for _, instruction in ipairs(action.system or {}) do
    --- @diagnostic disable-next-line: param-type-mismatch
    table.insert(obj.system_instructions, { instruction = vim.deepcopy(instruction), context = obj.context })
  end

  for _, instruction in ipairs(action.examples or {}) do
    --- @diagnostic disable-next-line: param-type-mismatch
    table.insert(obj.example_instructions, { instruction = vim.deepcopy(instruction), context = obj.context })
  end

  for _, instruction_option in ipairs(Conversation.prending_instructions) do
    table.insert(obj.instructions, instruction_option)
  end
  Conversation.prending_instructions = {}

  for _, instruction in ipairs(action.instructions or {}) do
    --- @diagnostic disable-next-line: param-type-mismatch
    table.insert(obj.instructions, { instruction = vim.deepcopy(instruction), context = obj.context })
  end

  if action.reminder then
    --- @diagnostic disable-next-line: param-type-mismatch
    obj.reminder = { instruction = vim.deepcopy(action.reminder), context = obj.context }
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

--- @param name string
--- @return string? message
function Conversation:get_tool_message(name)
  local tool = self.tool_fn[name]
  if tool then
    return tool.message
  end

  return nil
end

--- @param tool string|sia.config.Tool
function Conversation:add_tool(tool)
  if type(tool) == "string" then
    tool = require("sia.config").options.defaults.tools.choices[tool]
  end
  if tool ~= nil and self.tool_fn[tool.name] == nil then
    self.tool_fn[tool.name] = { message = tool.message, action = tool.execute }
    table.insert(self.tools, tool)
  end
end

--- @param files string[]
function Conversation:add_files(files)
  for _, file in ipairs(files) do
    if not vim.tbl_contains(self.files, file) then
      self.files[#self.files + 1] = { path = file }
    end
  end
end

--- @param file string|{path: string, pos: [integer, integer]?}
function Conversation:add_file(file)
  if type(file) == "string" then
    file = { path = file }
  end

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
      if vim.fn.match(file.path, regex) ~= -1 then
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

--- @param instruction sia.config.Instruction|sia.config.Instruction[]|string
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

--- @param index {kind:string, index:number}
function Conversation:remove_instruction(index)
  local removed

  if index.kind == "system" then
    removed = table.remove(self.system_instructions, index.index)
  elseif index.kind == "example" then
    removed = table.remove(self.example_instructions, index.index)
  elseif index.kind == "files" then
    removed = table.remove(self.files, index.index)
  elseif index.kind == "user" then
    removed = table.remove(self.instructions, index.index)
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
    return self.system_instructions[index.index]
  elseif index.kind == "example" then
    return self.example_instructions[index.index]
  elseif index.kind == "files" then
    return self.files[index.index]
  elseif index.kind == "user" then
    return self.instructions[index.index]
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
--- @param callback  fun(opts: {content: string[]?, confirmation: string[]?, bufs: [integer]?}?):nil
--- @return string[]?
function Conversation:execute_tool(name, arguments, strategy, callback)
  if self.tool_fn[name] then
    return self.tool_fn[name].action(arguments, strategy.conversation, callback)
  else
    callback(nil)
  end
end

--- @param opts {filter: (fun(message: sia.Message):boolean)?, mapping: boolean?}?
--- @return sia.Message[] messages
--- @return {kind: string, index: integer}[]? mappings if mapping is set to true
function Conversation:get_messages(opts)
  opts = opts or {}

  local instopt_kinds = {
    { kind = "system", instructions = self.system_instructions },
    { kind = "example", instructions = self.example_instructions },
    { kind = "files", instructions = get_files_instructions(self.files) },
    { kind = "user", instructions = self.instructions },
  }
  local mappings = {}
  local return_messages = {}
  for _, instopt_kind in ipairs(instopt_kinds) do
    for i, instrop in ipairs(instopt_kind.instructions) do
      local messages = self:_to_message(instrop)
      if messages then
        for _, message in ipairs(messages) do
          if message:is_available() and (opts.filter == nil or opts.filter(message)) then
            table.insert(return_messages, message)
            table.insert(mappings, { kind = instopt_kind.kind, index = i })
          end
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
  --- @type sia.Prompt[]
  local prompt = vim
    .iter(self:get_messages())
    --- @param m sia.Message
    --- @return boolean
    :filter(function(m)
      return m:is_available()
    end)
    --- @param m sia.Message
    --- @return sia.Prompt
    :map(function(m)
      return m:to_prompt()
    end)
    --- @param p sia.Prompt
    --- @return boolean?
    :filter(function(p)
      return (p.content and p.content ~= "") or (p.tool_calls and #p.tool_calls > 0)
    end)
    :totable()

  if self.reminder then
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

  --- @type sia.Query
  return {
    model = self.model,
    temperature = self.temperature,
    prompt = prompt,
    tools = tools,
  }
end

return { Message = Message, Conversation = Conversation }
