--- @alias sia.Prompt {role: sia.config.Role, content: string?, tool_calls: sia.ToolCall[]?, tool_call_id: string? }
--- @alias sia.Query { model: string?, temperature: number?, prompt: sia.Prompt, tools: sia.Tool[]?}
--- @alias sia.Tool { type: "function", function: { name: string, description: string, parameters: {type: "object", properties: table<string, sia.ToolParameter>?, required: string[]?, additionalProperties: boolean?}}}
--- @alias sia.ToolParameter { type: "number"|"string"?, enum: string[]?, description: string? }

--- @class sia.ActionArgument
--- @field start_line integer?
--- @field end_line integer?
--- @field mode "v"|"n"?
--- @field bang boolean?
--- @field buf number
--- @field win number?
--- @field cursor integer[]

--- @class sia.Context
--- @field buf integer
--- @field win integer?
--- @field pos [integer,integer]?
--- @field mode "n"|"v"?
--- @field bang boolean?
--- @field cursor integer[]

--- @class sia.Message
--- @field id (fun(ctx:sia.Context?):table?)?
--- @field role sia.config.Role
--- @field hide boolean?
--- @field content (string[]|string|(fun(ctx:sia.Context?):string))?
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call_id string?
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
  if instruction._tool_call_id then
    obj._tool_call_id = instruction._tool_call_id
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
--- @param instruction sia.config.Instruction|string|fun()|sia.config.Instruction[]|sia.config.Instruction[]
--- @param args sia.Context?
--- @return sia.Message[]?
function Message:new(instruction, args)
  if type(instruction) == "function" then
    instruction = instruction()
  end

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
  if self._tool_call_id then
    prompt.tool_call_id = self._tool_call_id
  end
  return prompt
end

--- @return boolean
function Message:is_context()
  return self.role == "user" and self.persistent == true and self:is_available()
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
  if type(self.description) == "function" then
    return self.description(self.context)
  else
    local description = self.description
    --- @cast description string?
    return description or "[No name]"
  end
end

--- @alias sia.InstructionOption (string|sia.config.Instruction|(fun():sia.config.Instruction[]))
--- @class sia.Conversation
--- @field instructions {instruction: sia.InstructionOption, context: sia.Context?}[]
--- @field reminder { instruction: (string|sia.config.Instruction)?, context: sia.Context? }
--- @field tools sia.config.Tool[]?
--- @field model string?
--- @field temperature number?
--- @field mode sia.config.ActionMode?
--- @field context sia.Context
--- @field tool_fn table<string, fun(arguments: table, callback: fun(content: string[]?):nil)>?
local Conversation = {}

Conversation.__index = Conversation
Conversation._buffers = {}

--- @param action sia.config.Action
--- @param args sia.ActionArgument
--- @return sia.Conversation
function Conversation:new(action, args)
  local obj = setmetatable({}, self)
  obj.model = action.model
  obj.temperature = action.temperature
  obj.mode = action.mode
  obj.context = {
    buf = args.buf,
    win = args.win,
    mode = args.mode,
    bang = args.bang,
    pos = { args.start_line, args.end_line },
    cursor = args.cursor,
  }
  obj.instructions = {}
  for _, instruction in ipairs(action.instructions or {}) do
    table.insert(obj.instructions, { instruction = vim.deepcopy(instruction), context = obj.context })
  end
  if action.reminder then
    obj.reminder = { instruction = vim.deepcopy(action.reminder), context = obj.context }
  end
  obj.tools = action.tools
  obj.tool_fn = {}
  for _, tool in ipairs(action.tools or {}) do
    obj.tool_fn[tool.name] = tool.execute
  end

  return obj
end

--- @param id table?
--- @return boolean
function Conversation:contains_message(id)
  if id then
    for _, other in ipairs(self.instructions) do
      local messages = Message:new(other.instruction, other.context)
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

--- @param instruction sia.config.Instruction
--- @param args sia.Context?
--- @return boolean
function Conversation:add_instruction(instruction, args)
  local tmp_messages = Message:new(instruction, args)
  local contains = false
  for _, message in ipairs(tmp_messages or {}) do
    local message_id = message:get_id()
    if self:contains_message(message_id) then
      contains = true
    end
  end
  if not contains then
    table.insert(self.instructions, { instruction = instruction, context = args })
    return true
  end

  return false
end

--- @return sia.Message message
function Conversation:last_message()
  local instruction = self.instructions[#self.instructions]
  local messages = Message:new(instruction.instruction, instruction.context)
  if not messages then
    error("No messages found")
  end
  return messages[#messages]
end

--- @return string[] descriptionb
--- @return integer[] mapping
function Conversation:get_context_instructions()
  local contexts = {}
  local mappings = {}
  for i, instruction in ipairs(self.instructions) do
    local context = {}
    for _, message in ipairs(Message:new(instruction.instruction, instruction.context) or {}) do
      if message:is_context() then
        table.insert(context, message:get_description())
      end
    end
    if #context > 0 then
      mappings[#mappings + 1] = i
      contexts[#contexts + 1] = table.concat(context, ", ")
    end
  end
  return contexts, mappings
end

function Conversation:remove_instruction(index)
  table.remove(self.instructions, index)
end

function Conversation:get_context_messages()
  local messages = {}
  for _, instruction in ipairs(self.instructions) do
    for _, message in ipairs(Message:new(instruction.instruction, instruction.context) or {}) do
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
    return self.tool_fn[name](arguments, strategy, callback)
  end
end

--- @return sia.Message[] messages
function Conversation:get_messages()
  return vim
    .iter(self.instructions)
    --- @param instruction {instruction: sia.InstructionOption, context: sia.Context? }
    :map(function(instruction)
      return Message:new(instruction.instruction, instruction.context)
    end)
    :flatten()
    :filter(function(m)
      return m:is_available()
    end)
    :totable()
end

--- @return sia.Query
function Conversation:to_query()
  local prompt = vim
    .iter(self.instructions)
    --- @param instruction {instruction: sia.InstructionOption, context: sia.Context?}
    :map(function(instruction)
      return Message:new(instruction.instruction, instruction.context)
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
    for _, reminder in ipairs(Message:new(self.reminder.instruction, self.reminder.context) or {}) do
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
