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
--- @field role "user"|"assistant"|"system"
--- @field content string[]|string|(fun(ctx:sia.Context):string?)
--- @field persistent boolean?
--- @field information ((fun(ctx: sia.Context):string)|string)?
--- @field context sia.Context
local Message = {}
Message.__index = Message

--- @param instruction sia.config.Instruction
--- @param args sia.ActionArgument
--- @return sia.Message
function Message:from_table(instruction, args)
  local obj = setmetatable({}, self)
  args = args or {}
  obj.role = instruction.role
  obj.content = instruction.content
  obj.information = instruction.information
  obj.persistent = instruction.persistent
  obj.context = {
    buf = args.buf,
    win = args.win,
    mode = args.mode,
    bang = args.bang,
    cursor = args.cursor,
    pos = { args.start_line, args.end_line },
  }
  return obj
end

--- Create a new message from a stored instruction
--- @param str string|string[]
--- @param args sia.ActionArgument
--- @return sia.Message?
function Message:from_string(str, args)
  if type(str) == "string" then
    local step = require("sia.config").options.instructions[str]
    if step then
      return Message:from_table(step, args)
    end
  end
end

--- Create a new message from an Instruction or a stored instruction.
--- @param instruction sia.config.Instruction|string
--- @param args sia.ActionArgument
--- @return sia.Message?
function Message:new(instruction, args)
  if type(instruction) == "string" then
    return Message:from_string(instruction, args)
  else
    return Message:from_table(instruction, args)
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

function Message:is_context()
  return self.role == "user" and self.persistent
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

--- @return string?
function Message:get_information()
  if type(self.information) == "function" then
    return self.information(self.context)
  else
    local information = self.information
    --- @cast information string?
    return information
  end
end

-- --- @param buf number
-- function Message:render(buf)
--   if self.role == "assistant" or self.role == "system" or self.persistent then
--     return
--   end
--
--   --- @type string[]?
--   local content
--   if type(self.content) == "function" then
--     local tmp = self.content(self.context)
--     if tmp then
--       content = vim.split(tmp, "\n", { trimempty = true })
--     end
--   elseif type(self.content) == "table" then
--     local tmp = self.content
--     --- @cast tmp string[]
--     content = tmp
--   else
--     local tmp = self.content
--     --- @cast tmp string
--     content = vim.split(tmp, "\n", { trimempty = true })
--   end
--
--   if content then
--     local line = vim.api.nvim_buf_line_count(buf)
--     if line == 1 then
--       vim.api.nvim_buf_set_lines(buf, line - 1, line, false, { "# User" })
--     else
--       vim.api.nvim_buf_set_lines(buf, line, line, false, { "", "# User" })
--     end
--     vim.api.nvim_buf_set_lines(buf, -1, -1, false, content)
--   end
-- end

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
  if args then
    obj.context = {
      buf = args.buf,
      win = args.win,
      mode = args.mode,
      bang = args.bang,
      pos = { args.start_line, args.end_line },
      cursor = args.cursor,
    }
  end
  obj.messages = {}
  for i, message in ipairs(action.instructions or {}) do -- Empty initial conversation...
    obj.messages[i] = Message:new(message, args)
  end

  return obj
end

--- @param message sia.Message a context message
function Conversation:add_message(message)
  table.insert(self.messages, message)
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
