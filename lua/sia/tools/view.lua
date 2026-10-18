local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local tool_names = tool_utils.tool_names

--- Determine the kind of view and return display helpers
--- @param path string
--- @return { label: fun(path: string): string }
local function view_display(path)
  if require("sia.utils").dirs.is_safe(path) then
    return {
      label = function()
        return "tool output"
      end,
    }
  end

  return {
    label = function(p)
      return vim.fn.fnamemodify(p, ":.")
    end,
  }
end

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = tool_names.view,
    description = [[Views a file from the local filesystem. By default, it reads up to
2000 lines starting from the beginning of the file. You can optionally specify a line
offset and limit (especially handy for long files), but it`s RECOMMENDED TO READ THE
WHOLE FILE by not providing these parameters. Any lines longer than 2000 characters
will be truncated.

Output includes a [PATH#TAG] snapshot header and LINE:TEXT rows for the edit tool.
Truncated lines cannot be edited; read the complete lines before editing them.]],
    parameters = {
      path = { type = "string", description = "The file path" },
      offset = {
        type = "integer",
        description = "Line offset to start reading from (1-based, optional)",
      },
      limit = {
        type = "integer",
        description = "Maximum number of lines to read (default: 2000)",
      },
    },
    required = { "path" },
  },
  read_only = true,
  summary = function(args)
    return "Reading " .. (args.path or "file") .. "..."
  end,

  persist_allow = function(args)
    return tool_utils.path_allow_rules("path", args.path)
  end,
  is_approved = function(args, _)
    if args.path then
      if require("sia.utils").dirs.is_safe(args.path) then
        return true
      end
    end
    return false
  end,
}, function(args, conversation, callback, opts)
  if not args.path then
    callback({
      content = "Error: No file path was provided",
      summary = "Failed to view",
      ephemeral = true,
    })
    return
  end

  local resolved_path =
    tool_utils.resolve_workspace_path(args.path, conversation.workspace)

  if vim.fn.filereadable(resolved_path) == 0 then
    callback({
      content = "Error: File cannot be found",
      summary = "Failed to view",
      ephemeral = true,
    })
    return
  end

  local offset = tonumber(args.offset) or 1
  local limit = args.limit or 2000
  local confirm_message
  if args.offset then
    confirm_message = string.format(
      "View lines %d-%d from %s",
      args.offset,
      args.offset + limit - 1,
      args.path
    )
  else
    confirm_message = string.format("View %s (up to %d lines)", args.path, limit)
  end

  opts.user_input(confirm_message, {
    on_accept = function()
      local buf = utils.ensure_file_is_loaded(resolved_path, {
        read_only = true,
        listed = false,
      })
      if not buf then
        callback({
          content = "Error: Cannot load " .. args.path,
          summary = "Failed to view",
          ephemeral = true,
        })
        return
      end
      local context = require("sia.tools.file_context").build(conversation, resolved_path, buf, {
        first = offset,
        limit = limit,
        whole_buffer = not (args.offset or args.limit),
      })
      local start_line, end_line = context.first, context.last

      local display = view_display(args.path)
      local name = display.label(args.path)

      local summary = "Read " .. name
      if args.offset or args.limit then
        summary = summary .. string.format(":%d-%d", start_line, end_line)
      end

      callback({
        content = context.content,
        region = context.region,
        summary = summary,
      })
    end,
  })
end)
