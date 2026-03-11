--- @class sia.history.HistoryLogger
--- @field id string?
local M = {}
M.__index = M

local ENABLE = false
local SKIP_RECONSTRUCT = { dropped = true, superseded = true, failed = true }

--- @class sia.history.StartEvent
--- @field id string
--- @field provider string
--- @field api_name string
--- @field config table

--- @class sia.history.LoadedConversation
--- @field model sia.Model?
--- @field messages sia.config.Instruction[]

--- @class sia.history.Message
--- @field id string
--- @field template boolean?
--- @field turn_id string
--- @field role "user"|"system"|"assistant"
--- @field content (string|sia.Content[])?
--- @field tool_calls sia.ToolCall[]?
--- @field meta table?
--- @field outdated string?

--- @class sia.history.ToolMessage
--- @field id string
--- @field turn_id string
--- @field role "tool"
--- @field tool_call sia.ToolCall
--- @field content string
--- @field meta table?
--- @field outdated string?

--- @class sia.history.MessageStatusChange
--- @field id string
--- @field status string

--- @class sia.history.Tools
--- @field tools { name: string, module: string? }[]

--- @alias sia.history.Event sia.history.StartEvent|sia.history.ToolMessage|sia.history.Message|sia.history.MessageStatusChange|sia.Usage|sia.history.Tools

local HISTORY_DIR = vim.fs.joinpath(vim.fn.stdpath("cache"), "sia", "conversations")
local function ensure_hisory_file(id)
  if vim.fn.isdirectory(HISTORY_DIR) == 0 then
    vim.fn.mkdir(HISTORY_DIR, "p")
  end
  return vim.fs.joinpath(HISTORY_DIR, id .. ".json")
end

--- @param id string?
function M.new(id)
  local self = setmetatable({
    id = id,
  }, M)

  return self
end

--- @param model sia.Model
function M:created(model)
  self:log("conversation_created", {
    id = self.id,
    provider = model.provider_name,
    api_name = model.api_name,
    config = model.config,
  })
end

--- @param message sia.Message
function M:message_created(message)
  if message.role == "tool" then
    self:log("tool_call_created", {
      id = message.id,
      role = "tool",
      meta = message.meta,
      turn_id = message.turn_id,
      content = message.content,
      tool_call = message._tool_call,
      outdated = message.context and message.context.outdated_message,
    })
  elseif
    message.tool_calls ~= nil
    or message.content ~= nil
    or message.meta.empty_content == true
  then
    self:log("message_created", {
      id = message.id,
      template = message.template,
      role = message.role,
      content = message.content,
      tool_calls = message.tool_calls,
      turn_id = message.turn_id,
      meta = message.meta,
      outdated = message.context and message.context.outdated_message,
    })
  end
end

function M:message_status_change(message)
  if message.status then
    self:log("message_changed", { id = message.id, status = message.status })
  end
end

--- @param usage sia.Usage
function M:usage_created(usage)
  self:log("usage_created", usage)
end

--- @param tools sia.config.Tool[]
function M:tools_registered(tools)
  local entries = {}
  for _, tool in ipairs(tools) do
    table.insert(entries, { name = tool.name, module = tool.module })
  end
  self:log("tools_registered", { tools = entries })
end

function M:destroyed()
  self:log("conversation_destroyed")
end

--- @param tag string
--- @param event sia.history.Event?
function M:log(tag, event)
  if self.id and ENABLE then
    local file = ensure_hisory_file(self.id)
    event = event or {} --[[@as table]]
    event.type = tag
    event.time = os.time()
    vim.fn.writefile({ vim.json.encode(event) }, file, "a")
  end
end

--- Load and reconstruct a conversation from a history file.
---
--- Returns a list of `sia.config.Instruction`-like tables that can be passed back
--- into `Conversation:add_instruction`. Outdated messages have their content replaced
--- with the stored `outdated` hint (mirroring `get_message_content` in conversation.lua).
--- Messages whose final status is "dropped", "superseded", or "failed" are excluded.
---
--- @param id string  UUID of the conversation to load
--- @return sia.history.LoadedConversation?
function M.load(id)
  local path = vim.fs.joinpath(HISTORY_DIR, id .. ".json")
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  local lines = vim.fn.readfile(path)

  --- @type table<string, sia.history.Message|sia.history.ToolMessage>
  local by_id = {}
  --- ordered list of message ids as they were created
  --- @type string[]
  local order = {}
  --- @type sia.history.StartEvent?
  local model_event = nil

  for _, line in ipairs(lines) do
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" then
        local t = event.type
        if t == "conversation_created" then
          model_event = event
        elseif t == "message_created" or t == "tool_call_created" then
          by_id[event.id] = event
          table.insert(order, event.id)
        elseif t == "message_changed" then
          local msg = by_id[event.id]
          if msg then
            msg._status = event.status
          end
        end
      end
    end
  end

  --- @type sia.Model?
  local model = nil
  if model_event and model_event.config then
    local ok, result = pcall(require("sia.model").resolve, model_event.config)
    if ok then
      model = result
    end
  end

  --- @type sia.config.Instruction[]
  local messages = {}
  for _, mid in ipairs(order) do
    local event = by_id[mid]
    if event and not SKIP_RECONSTRUCT[event._status] then
      --- @type sia.config.Instruction
      local instr = {
        role = event.role,
        tool_calls = event.tool_calls,
        _tool_call = event.tool_call,
        meta = event.meta,
        template = event.template,
        turn_id = event.turn_id,
      }

      -- On reload we cannot re-evaluate tick-based staleness, so we conservatively
      -- outdate any message that either (a) was already marked outdated, or
      -- (b) carries an outdated hint (meaning it *could* become stale).
      local is_outdated = event._status == "outdated"
        or (event.role ~= "system" and event.outdated ~= nil)
      if is_outdated and event.content ~= nil and not event.meta.empty_content then
        instr.content =
          string.format("System Note: History pruned. %s", event.outdated or "")
      else
        instr.content = event.content
      end

      table.insert(messages, instr)
    end
  end

  return { model = model, messages = messages }
end

--- Return a list of conversation UUIDs that have history files on disk,
--- ordered newest-first by file modification time.
--- @return string[]
function M.list()
  if vim.fn.isdirectory(HISTORY_DIR) == 0 then
    return {}
  end
  local files = vim.fn.glob(HISTORY_DIR .. "/*.json", false, true)
  table.sort(files, function(a, b)
    return vim.fn.getftime(a) > vim.fn.getftime(b)
  end)
  local ids = {}
  for _, f in ipairs(files) do
    local name = vim.fn.fnamemodify(f, ":t:r")
    table.insert(ids, name)
  end
  return ids
end

function M.setup()
  ENABLE = true
end

return M
