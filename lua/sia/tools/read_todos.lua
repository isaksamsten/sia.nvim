local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "read_todos",
  read_only = true,
  message = "Reading todos...",
  system_prompt = [[Read the current list of todos for this conversation.

Returns all todos with their ID, description, and status. Use the IDs when updating todos
with the write_todos tool.]],
  description = "Get the current list of todos for this conversation",
  parameters = vim.empty_dict(),
  required = {},
  auto_apply = function(_, _)
    return 1
  end,
}, function(args, conversation, callback, _)
  if not conversation.todos then
    conversation.todos = { buf = nil, items = {} }
  end

  if #conversation.todos.items == 0 then
    callback({
      content = { "No todos yet. Use write_todos to add some!" },
    })
    return
  end

  local response = { "Current todos:" }
  table.insert(response, "")

  local by_status = {
    active = {},
    pending = {},
    done = {},
    skipped = {},
  }

  for _, todo in ipairs(conversation.todos.items) do
    local status = todo.status or "pending"
    table.insert(by_status[status], todo)
  end

  local order = { "active", "pending", "done", "skipped" }
  for _, status in ipairs(order) do
    local todos = by_status[status]
    if #todos > 0 then
      local status_label = status:upper()
      table.insert(response, string.format("%s", status_label))
      for _, todo in ipairs(todos) do
        table.insert(response, string.format("  [%d] %s", todo.id, todo.description))
      end
      table.insert(response, "")
    end
  end

  callback({
    content = response,
  })
end)
