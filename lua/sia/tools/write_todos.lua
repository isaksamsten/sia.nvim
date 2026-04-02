local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = "write_todos",
    description = "Add, update, or clear todos for this conversation",
    parameters = {
      replace = {
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
        description = "Replace all existing todos with this new list",
      },
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
  },
  read_only = false,
  notification = function(args)
    local parts = {}
    if args.replace and #args.replace > 0 then
      table.insert(parts, string.format("replacing with %d todo(s)", #args.replace))
    end
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
  instructions = [[Manage todos for this conversation. You can add new todos, update
existing ones, clear completed todos, or replace the entire list.

The tool returns a summary of what was added, updated, or cleared, including the IDs
of newly added todos for future reference.]],
}, function(args, conversation, callback, _)
  if not conversation.todos then
    conversation.todos = { items = {} }
  end

  local response = {}

  local next_id = 1
  for _, todo in ipairs(conversation.todos.items) do
    if todo.id >= next_id then
      next_id = todo.id + 1
    end
  end

  if args.replace and #args.replace > 0 then
    conversation.todos.items = {}
    next_id = 1
    table.insert(response, "Replaced all todos with:")
    for _, new_todo in ipairs(args.replace) do
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

  local all_completed = true
  for _, todo in ipairs(conversation.todos.items) do
    if todo.status ~= "done" and todo.status ~= "skipped" then
      all_completed = false
      break
    end
  end

  local todos_ui = require("sia.ui.todos")

  if all_completed or #conversation.todos.items == 0 then
    response = { "All items are done or skipped!" }
    vim.schedule(function()
      todos_ui.close(conversation)
    end)
  else
    vim.schedule(function()
      todos_ui.open(conversation)
    end)
  end

  if #response == 0 then
    table.insert(response, "No changes made. Specify add, update, or clear parameters.")
  end

  callback({
    content = table.concat(response, "\n"),
  })
end)
