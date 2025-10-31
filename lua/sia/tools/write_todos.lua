local tool_utils = require("sia.tools.utils")

local STATUS_NS = vim.api.nvim_create_namespace("sia_todos")
local STATUS = {
  active = { icon = "▶", hl_group = "SiaTodoActive" },
  pending = { icon = "○", hl_group = "SiaTodoPending" },
  done = { icon = "✓", hl_group = "SiaTodoDone" },
  skipped = { icon = "⊗", hl_group = "SiaTodoSkipped" },
}
--- Render todos to buffer
--- @param conversation sia.Conversation
local function render_todos_buffer(conversation)
  local buf = conversation.todos.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  if #conversation.todos.items == 0 then
    return
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(buf, STATUS_NS, 0, -1)
  for i, todo in ipairs(conversation.todos.items) do
    local status = STATUS[todo.status]
    local icon = status and status.icon or "•"
    local hl_group = status and status.hl_group or "Normal"
    local line = string.format("%s %s", icon, todo.description:gsub("\n", " "))
    vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { line })
    vim.api.nvim_buf_set_extmark(buf, STATUS_NS, i - 1, 0, {
      end_col = #line,
      hl_group = hl_group,
      hl_mode = "combine",
    })
  end
  vim.bo[buf].modifiable = false
end

--- Toggle todo status between pending, done, and skipped
--- @param conversation sia.Conversation
local function toggle_todo_status(conversation)
  local line_num = vim.api.nvim_win_get_cursor(0)[1]
  if line_num < 1 or line_num > #conversation.todos.items then
    return
  end

  local todo = conversation.todos.items[line_num]
  if not todo then
    return
  end

  local status_cycle = {
    pending = "done",
    done = "skipped",
    skipped = "pending",
    active = "done",
  }

  todo.status = status_cycle[todo.status] or "pending"

  local buf = conversation.todos.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.bo[buf].modifiable = true
  local status = STATUS[todo.status]
  local icon = status and status.icon or "•"
  local hl_group = status and status.hl_group or "Normal"
  local line = string.format("%s %s", icon, todo.description:gsub("\n", " "))
  vim.api.nvim_buf_set_lines(buf, line_num - 1, line_num, false, { line })
  vim.api.nvim_buf_set_extmark(buf, STATUS_NS, line_num - 1, 0, {
    end_col = #line,
    hl_group = hl_group,
    hl_mode = "combine",
  })
  vim.bo[buf].modifiable = false
end

--- Set up buffer-local keybindings
--- @param buf integer
--- @param conversation sia.Conversation
local function setup_keybindings(buf, conversation)
  vim.keymap.set("n", "<CR>", function()
    toggle_todo_status(conversation)
  end, { buffer = buf, nowait = true, desc = "Toggle todo status" })
end

--- Create or get the todos buffer
--- @return integer
local function create_todos_buffer()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false

  return buf
end

return tool_utils.new_tool({
  name = "write_todos",
  read_only = false,
  message = function(args)
    local parts = {}
    if args.add and #args.add > 0 then
      table.insert(parts, string.format("adding %d todo(s)", #args.add))
    end
    if args.update and #args.update > 0 then
      table.insert(parts, string.format("updating %d todo(s)", #args.update))
    end
    if args.clear then
      table.insert(parts, "clearing completed todos")
    end
    return "Writing todos: " .. table.concat(parts, ", ")
  end,
  system_prompt = [[Manage todos for this conversation. You can add new todos, update
existing ones, or clear completed todos.

The tool returns a summary of what was added, updated, or cleared, including the IDs
of newly added todos for future reference.]],
  description = "Add, update, or clear todos for this conversation",
  parameters = {
    add = {
      type = "array",
      items = {
        type = "object",
        properties = {
          description = { type = "string", description = "Task description" },
          status = {
            type = "string",
            enum = { "pending", "active", "done", "skipped" },
            description = "Initial status (default: pending)",
          },
        },
        required = { "description" },
      },
      description = "New todos to add",
    },
    update = {
      type = "array",
      items = {
        type = "object",
        properties = {
          id = { type = "integer", description = "ID of todo to update" },
          status = {
            type = "string",
            enum = { "pending", "active", "done", "skipped" },
            description = "New status",
          },
        },
        required = { "id", "status" },
      },
      description = "Todo updates by ID",
    },
    clear = {
      type = "boolean",
      description = "Remove all completed (done/skipped) todos",
    },
  },
  required = {},
}, function(args, conversation, callback, _)
  if not conversation.todos then
    conversation.todos = { buf = nil, items = {} }
  end

  local is_first_time = false
  if
    not conversation.todos.buf or not vim.api.nvim_buf_is_valid(conversation.todos.buf)
  then
    local buf = create_todos_buffer()
    pcall(
      vim.api.nvim_buf_set_name,
      buf,
      string.format("*%s todos*", conversation.name)
    )

    setup_keybindings(buf, conversation)
    is_first_time = true
    conversation.todos.buf = buf
  end

  local response = {}

  local next_id = 1
  for _, todo in ipairs(conversation.todos.items) do
    if todo.id >= next_id then
      next_id = todo.id + 1
    end
  end

  if args.add and #args.add > 0 then
    table.insert(response, "Added todos:")
    for _, new_todo in ipairs(args.add) do
      local todo = {
        id = next_id,
        description = new_todo.description,
        status = new_todo.status or "pending",
      }
      table.insert(conversation.todos.items, todo)
      table.insert(
        response,
        string.format("  - [%d] %s (%s)", todo.id, todo.description, todo.status)
      )
      next_id = next_id + 1
    end
    table.insert(response, "")
  end

  if args.update and #args.update > 0 then
    table.insert(response, "Updated todos:")
    for _, update in ipairs(args.update) do
      local found = false
      for _, todo in ipairs(conversation.todos.items) do
        if todo.id == update.id then
          local old_status = todo.status
          todo.status = update.status
          table.insert(
            response,
            string.format(
              "  - [%d] %s (%s → %s)",
              todo.id,
              todo.description,
              old_status,
              todo.status
            )
          )
          found = true
          break
        end
      end
      if not found then
        table.insert(response, string.format("  - [%d] NOT FOUND", update.id))
      end
    end
    table.insert(response, "")
  end

  if args.clear then
    local new_todos = {}
    local cleared_count = 0
    for _, todo in ipairs(conversation.todos.items) do
      if todo.status ~= "done" and todo.status ~= "skipped" then
        table.insert(new_todos, todo)
      else
        cleared_count = cleared_count + 1
      end
    end
    conversation.todos.items = new_todos
    table.insert(response, string.format("Cleared %d completed todo(s)", cleared_count))
    table.insert(response, "")
  end

  render_todos_buffer(conversation)

  if is_first_time and args.add and #args.add > 0 then
    vim.schedule(function()
      require("sia").todos("open")
    end)
  end

  local all_completed = true
  for _, todo in ipairs(conversation.todos.items) do
    if todo.status ~= "done" and todo.status ~= "skipped" then
      all_completed = false
      break
    end
  end

  if all_completed or #conversation.todos.items == 0 then
    conversation.todos.items = {}
    response = { "All items are done or skipped!" }
    vim.schedule(function()
      require("sia").todos("close")
    end)
  end

  if #response == 0 then
    table.insert(response, "No changes made. Specify add, update, or clear parameters.")
  end

  callback({
    content = response,
  })
end)
