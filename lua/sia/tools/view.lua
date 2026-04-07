local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons
local tool_names = tool_utils.tool_names

--- Determine the kind of view and return display helpers
--- @param path string
--- @return { icon: string, label: fun(path: string): string }
local function view_display(path)
  if require("sia.utils").dirs.is_safe(path) then
    return {
      icon = icons.view_bash,
      label = function()
        return "tool output"
      end,
    }
  end

  return {
    icon = icons.view,
    label = function(p)
      return vim.fn.fnamemodify(p, ":.")
    end,
  }
end

local outdated_tpl = string.format(
  "Previously viewed %%s from %%s - file was modified, use %s tool to get current content",
  tool_names.view
)

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = tool_names.view,
    description = [[Views a file from the local filesystem.]],
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
    if args.path then
      return "Viewing " .. vim.fn.fnamemodify(args.path, ":t")
    else
      return "Viewing..."
    end
  end,
  instructions = [[Views a file from the local filesystem. By default, it reads up to
2000 lines starting from the beginning of the file. You can optionally specify a line
offset and limit (especially handy for long files), but it`s RECOMMENDED TO READ THE
WHOLE FILE by not providing these parameters. Any lines longer than 2000 characters
will be truncated.]],
  persist_allow = function(args)
    return tool_utils.path_allow_rules("path", args.path)
  end,
  auto_apply = function(args, _)
    if args.path then
      if require("sia.utils").dirs.is_safe(args.path) then
        return 1
      end
    end
    return nil
  end,
}, function(args, conversation, callback, opts)
  if not args.path then
    callback({
      content = "Error: No file path was provided",
      summary = icons.error .. " Failed to view",
      ephemeral = true,
    })
    return
  end

  if vim.fn.filereadable(args.path) == 0 then
    callback({
      content = "Error: File cannot be found",
      summary = icons.error .. " Failed to view",
      ephemeral = true,
    })
    return
  end

  local offset = tonumber(args.offset) or 1
  local limit = args.limit or 2000
  local max_line_length = 2000
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
      local buf = utils.ensure_file_is_loaded(args.path, {
        read_only = true,
        listed = false,
      })
      if not buf then
        callback({
          content = "Error: Cannot load " .. args.path,
          summary = icons.error .. " Failed to view",
          ephemeral = true,
        })
        return
      end
      local total_lines = vim.api.nvim_buf_line_count(buf)

      if offset > total_lines then
        offset = total_lines
      end

      local start_line = math.max(1, offset)
      local end_line = math.min(total_lines, start_line + limit - 1)

      local content = utils.get_content(
        buf,
        start_line - 1,
        end_line,
        { show_line_numbers = true, max_line_length = max_line_length }
      )

      local pos = nil
      if args.offset or args.limit then
        pos = { offset, offset + #content - 1 }
      end

      local display = view_display(args.path)
      local name = display.label(args.path)

      local summary
      if args.offset or args.limit then
        summary = string.format(
          "%s Viewed lines %d-%d from %s",
          display.icon,
          start_line,
          end_line,
          name
        )
      else
        summary = string.format("%s Viewed %s (%d lines)", display.icon, name, #content)
      end

      local outdated_message
      if args.offset or args.limit then
        local span = start_line ~= end_line
            and string.format("lines %d-%d", start_line, end_line)
          or string.format("line %d", start_line)
        outdated_message =
          string.format(outdated_tpl, span, vim.fn.fnamemodify(args.path, ":."))
      else
        local span = end_line > 1 and string.format("lines %d-%d", start_line, end_line)
          or string.format("line %d", start_line)
        outdated_message =
          string.format(outdated_tpl, span, vim.fn.fnamemodify(args.path, ":."))
      end

      callback({
        content = table.concat(content, "\n"),
        region = {
          buf = buf,
          pos = pos,
          stale = {
            content = outdated_message,
          },
          idempotent = true,
        },
        summary = summary,
      })
    end,
  })
end)
