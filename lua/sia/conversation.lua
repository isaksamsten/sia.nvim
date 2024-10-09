--- @alias sia.Prompt {role: "user"|"assistant"|"system", content: string}
--- @alias sia.Query { model: string?, temperature: number?, prompt: sia.Prompt}

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
--- @field id table?
--- @field role "user"|"assistant"|"system"
--- @field hide boolean?
--- @field content string[]|string|(fun(ctx:sia.Context?):string)
--- @field persistent boolean?
--- @field available (fun(ctx: sia.Context?):boolean)?
--- @field description ((fun(ctx: sia.Context?):string)|string)?
--- @field context sia.Context?
local Message = {}
Message.__index = Message

--- @param instruction sia.config.Instruction
--- @param args sia.ActionArgument?
--- @return sia.Message
function Message:from_table(instruction, args)
  local obj = setmetatable({}, self)
  if instruction.id then
    obj.id = instruction.id(args)
  end
  obj.role = instruction.role
  obj.hide = instruction.hide
  obj.available = instruction.available
  obj.content = instruction.content
  obj.description = instruction.description
  obj.persistent = instruction.persistent
  if args then
    obj.context = {
      buf = args.buf,
      win = args.win,
      mode = args.mode,
      bang = args.bang,
      cursor = args.cursor,
      pos = { args.start_line, args.end_line },
    }
  end
  return obj
end

--- Create a new message from a stored instruction
--- @param str string|string[]
--- @param args sia.ActionArgument?
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
--- @param instruction sia.config.Instruction|string
--- @param args sia.ActionArgument?
--- @return sia.Message[]?
function Message:new(instruction, args)
  if type(instruction) == "string" then
    return Message:from_string(instruction, args)
  else
    return { Message:from_table(instruction, args) }
  end
end

--- @return sia.Prompt
function Message:to_prompt()
  local prompt = { role = self.role }
  if type(self.content) == "function" then
    prompt.content = self.content(self.context)
  elseif type(self.content) == "table" then
    local content = self.content
    --- @cast content [string]
    prompt.content = table.concat(content, "\n")
  else
    prompt.content = self.content
  end
  return prompt
end

--- @return boolean
function Message:is_context()
  return self.role == "user" and self.persistent == true and self:is_available()
end

--- @return boolean
function Message:is_available()
  if self.available then
    return self.available(self.context)
  end
  return true
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

--- @class sia.Conversation
--- @field messages sia.Message[]
--- @field model string?
--- @field temperature number?
--- @field mode sia.config.ActionMode?
--- @field context sia.Context
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
  obj.messages = {}
  for _, instruction in ipairs(action.instructions or {}) do
    local message = Message:new(instruction, args)
    if message then
      if type(message) == "table" then
        for _, m in ipairs(message) do
          table.insert(obj.messages, m)
        end
      else
        table.insert(obj.messages, message)
      end
    end
  end

  return obj
end

--- @return boolean
function Conversation:contains_message(message)
  if message.id then
    for _, other in ipairs(self.messages) do
      if other.id and vim.deep_equal(other.id, message.id) then
        return true
      end
    end
  end
  return false
end

--- @param message sia.Message a context message
--- @return boolean
function Conversation:add_message(message)
  if not self:contains_message(message) then
    table.insert(self.messages, message)
    return true
  end
  return false
end

--- @param instruction sia.config.Instruction
--- @param args sia.ActionArgument?
--- @return boolean
function Conversation:add_instruction(instruction, args)
  return self:add_message(Message:from_table(instruction, args))
end

--- @return sia.Message message
function Conversation:last_message()
  return self.messages[#self.messages]
end

--- @return sia.Message message
function Conversation:get_message(index)
  return self.messages[index]
end

--- @return sia.Message[] context the context
--- @return integer[] mapping mapping the index in context to messages
function Conversation:get_context_messages()
  local mapping = {}
  local messages = {}
  for i, message in ipairs(self.messages) do
    if message:is_context() then
      table.insert(messages, message)
      table.insert(mapping, i)
    end
  end
  return messages, mapping
end

function Conversation:remove_message(index)
  table.remove(self.messages, index)
end

--- @return sia.Query
function Conversation:to_query()
  return {
    model = self.model,
    temperature = self.temperature,
    prompt = vim
      .iter(self.messages)
      :filter(function(m)
        return m:is_available()
      end)
      :map(function(m)
        return m:to_prompt()
      end)
      :filter(function(p)
        return p.content and p.content ~= ""
      end)
      :totable(),
  }
end

return { Message = Message, Conversation = Conversation }
