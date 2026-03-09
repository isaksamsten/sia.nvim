local utils = require("sia.utils")
local tracker = require("sia.tracker")
local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons
local tool_names = tool_utils.tool_names

--- Determine the kind of view and return display helpers
--- @param path string
--- @return { icon: string, label: fun(path: string): string }
local function view_display(path)
  if tool_utils.is_tool_output_path(path) then
    return {
      icon = icons.view_bash,
      label = function()
        return "tool output"
      end,
    }
  end

  if require("sia.skills.registry").is_skill_path(path) then
    return {
      icon = icons.view_skill,
      label = function(p)
        return "skill " .. vim.fn.fnamemodify(p, ":h:t")
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
  name = tool_names.view,
  read_only = true,
  message = function(args)
    if args.path then
      return "Viewing " .. vim.fn.fnamemodify(args.path, ":t")
    else
      return "Viewing..."
    end
  end,
  system_prompt = [[Views a file from the local filesystem. By default, it reads up to
2000 lines starting from the beginning of the file. You can optionally specify a line
offset and limit (especially handy for long files), but it`s RECOMMENDED TO READ THE
WHOLE FILE by not providing these parameters. Any lines longer than 2000 characters
will be truncated.]],
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
  auto_apply = function(args, _)
    if args.path then
      if tool_utils.is_tool_output_path(args.path) then
        return 1
      end
      if require("sia.skills.registry").is_skill_path(args.path) then
        return 1
      end
    end
    return nil
  end,
}, function(args, conversation, callback, opts)
  if not args.path then
    callback({
      content = { "Error: No file path was provided" },
      display_content = icons.error .. " Failed to view",
      kind = "failed",
    })
    return
  end

  if vim.fn.filereadable(args.path) == 0 then
    callback({
      content = { "Error: File cannot be found" },
      display_content = icons.error .. " Failed to view",
      kind = "failed",
    })
    return
  end

  local offset = args.offset or 1
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
          content = { "Error: Cannot load " .. args.path },
          display_content = icons.error .. " Failed to view",
          kind = "failed",
        })
        return
      end
      local total_lines = vim.api.nvim_buf_line_count(buf)

      if offset > total_lines then
        callback({
          content = {
            string.format(
              "Error: Offset %d is beyond end of file (file has %d lines)",
              offset,
              total_lines
            ),
          },
          display_content = icons.error .. " Failed to view",
          kind = "failed",
        })
        return
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

      local display_content
      if args.offset or args.limit then
        display_content = string.format(
          "%s Viewed lines %d-%d from %s",
          display.icon,
          start_line,
          end_line,
          name
        )
      else
        display_content =
          string.format("%s Viewed %s (%d lines)", display.icon, name, #content)
      end

      local outdated_message
      if args.offset or args.limit then
        local span = start_line ~= end_line
            and string.format("lines %d-%d", start_line, end_line)
          or string.format("line %d", start_line)
        outdated_message = string.format(outdated_tpl, span, vim.fn.fnamemodify(args.path, ":."))
      else
        local span = end_line > 1 and string.format("lines %d-%d", start_line, end_line)
          or string.format("line %d", start_line)
        outdated_message = string.format(outdated_tpl, span, vim.fn.fnamemodify(args.path, ":."))
      end

      callback({
        content = content,
        context = {
          buf = buf,
          pos = pos,
          tick = tracker.ensure_tracked(buf, { id = conversation.id, pos = pos }),
          outdated_message = outdated_message,
        },
        kind = "context",
        display_content = display_content,
      })
    end,
  })
end)

