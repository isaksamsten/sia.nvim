local M = {}

local split = require("sia.ui.split")
local ListModel = require("sia.ui.list").ListModel
local ListView = require("sia.ui.list").ListView

local TODOS_NS = vim.api.nvim_create_namespace("sia_todos")

local STATUS = {
  active = { icon = "▶", hl = "SiaTodoActive" },
  pending = { icon = "○", hl = "SiaTodoPending" },
  done = { icon = "✓", hl = "SiaTodoDone" },
  skipped = { icon = "⊗", hl = "SiaTodoSkipped" },
}

local STATUS_CYCLE = {
  pending = "done",
  done = "skipped",
  skipped = "pending",
  active = "done",
}

local panel = split.new()

--- @class sia.todos.State
--- @field conversation sia.Conversation
--- @field buf integer
--- @field model sia.ui.ListModel
--- @field list_view sia.ui.ListView

--- @type table<integer, sia.todos.State>
local states = {}

--- @param tag string
--- @param id any
--- @param todo sia.conversation.Todo
--- @return sia.ui.RenderSpec
--- @diagnostic disable-next-line: unused-local
local function render_todo(tag, id, todo)
  local status = STATUS[todo.status] or STATUS.pending
  return {
    icon = status.icon,
    label = todo.description:gsub("\n", " "),
    hl = status.hl,
    actions = {
      toggle = function()
        todo.status = STATUS_CYCLE[todo.status] or "pending"
      end,
    },
  }
end

--- @param conversation sia.Conversation
--- @return sia.todos.State
local function ensure_state(conversation)
  local state = states[conversation.id]
  if state then
    state.conversation = conversation
    return state
  end

  local function items()
    return conversation.todos and conversation.todos.items or {}
  end

  local model = ListModel.new({
    sources = {
      {
        tag = "todo",
        items = items,
        id = function(o)
          return o.id
        end,
        refresh = function()
          return true
        end,
      },
    },
  })

  state = {
    conversation = conversation,
    buf = -1,
    model = model,
    list_view = ListView.new(model, {
      render = render_todo,
      expandable = false,
      empty_message = "No todos",
    }),
  }
  states[conversation.id] = state
  return state
end

--- @param state sia.todos.State
local function render_state_buffer(state)
  if not (state.buf and state.buf > 0 and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  state.model:rebuild()
  state.list_view:apply(state.buf, TODOS_NS)
end

--- @param buf integer
local function toggle_current(buf)
  local state
  for _, s in pairs(states) do
    if s.buf == buf then
      state = s
      break
    end
  end
  if not state then
    return
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  if state.list_view:has_action(line, "toggle") then
    state.list_view:trigger(line, "toggle")
    render_state_buffer(state)
  end
end

--- @param conversation sia.Conversation
--- @return integer buf
local function get_or_create_buf(conversation)
  local state = ensure_state(conversation)

  if state.buf > 0 and vim.api.nvim_buf_is_valid(state.buf) then
    render_state_buffer(state)
    return state.buf
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, string.format("*%s todos*", conversation.name))

  vim.keymap.set("n", "<CR>", function()
    toggle_current(buf)
  end, { buffer = buf, nowait = true, desc = "Toggle todo status" })

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      states[conversation.id] = nil
    end,
  })

  state.buf = buf
  render_state_buffer(state)
  return buf
end

M._get_or_create_buf = get_or_create_buf

--- Open the todos panel for a conversation, creating the buffer if needed.
--- Called by the write_todos tool after mutating data.
--- @param conversation sia.Conversation
function M.open(conversation)
  if not conversation.todos or #conversation.todos.items == 0 then
    return
  end

  local chat = require("sia.strategy").get_chat()
  if not chat or chat.conversation.id ~= conversation.id then
    return
  end

  local buf = get_or_create_buf(conversation)
  panel:open(chat.buf, buf)
end

--- Close the todos panel for a conversation.
--- @param conversation sia.Conversation
function M.close(conversation)
  local chat = require("sia.strategy").get_chat()
  if not chat or chat.conversation.id ~= conversation.id then
    return
  end
  M.render(conversation)
  panel:close(chat.buf)
end

--- Render the todos buffer for a conversation (if it exists).
--- @param conversation sia.Conversation
function M.render(conversation)
  local state = states[conversation.id]
  if state then
    render_state_buffer(state)
  end
end

--- Open/close/toggle the todos panel for the current chat.
--- @param action? "open"|"close"|"toggle"
function M.toggle(action)
  action = action or "toggle"

  local chat = require("sia.strategy").get_chat()
  if not chat then
    return
  end

  if action == "close" then
    M.render(chat.conversation)
    panel:close(chat.buf)
    return
  end

  if action == "toggle" and panel:is_open(chat.buf) then
    M.render(chat.conversation)
    panel:close(chat.buf)
    return
  end

  if not chat.conversation.todos or #chat.conversation.todos.items == 0 then
    return
  end

  local buf = get_or_create_buf(chat.conversation)
  panel:open(chat.buf, buf)
end

return M
