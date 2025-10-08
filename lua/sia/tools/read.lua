local utils = require("sia.utils")
local tracker = require("sia.tracker")
local tool_utils = require("sia.tools.utils")

local FAILED_TO_READ = "❌ Failed to read"

return tool_utils.new_tool({
  name = "read",
  read_only = true,
  message = "Reading file contents...",
  system_prompt = [[Reads a file from the local filesystem. By default, it reads up to
2000 lines starting from the beginning of the file. You can optionally specify a line
offset and limit (especially handy for long files), but it`s recommended to read the
whole file by not providing these parameters. Any lines longer than 2000 characters
will be truncated.]],
  description = [[Reads a file from the local filesystem.]],
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
    if utils.is_memory(args.path) then
      return 1
    end
    return nil
  end,
}, function(args, _, callback, opts)
  if not args.path then
    callback({
      content = { "Error: No file path was provided" },
      display_content = { FAILED_TO_READ },
      kind = "failed",
    })
    return
  end

  if vim.fn.filereadable(args.path) == 0 then
    callback({
      content = { "Error: File cannot be found" },
      display_content = { FAILED_TO_READ },
      kind = "failed",
    })
    return
  end

  local is_memory = utils.is_memory(args.path)
  local offset = args.offset or 1
  local limit = args.limit or 2000
  local max_line_length = 2000
  local confirm_message
  if args.offset then
    confirm_message = string.format(
      "Read lines %d-%d from %s",
      args.offset,
      args.offset + limit - 1,
      args.path
    )
  else
    confirm_message = string.format("Read %s (up to %d lines)", args.path, limit)
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
          display_content = { FAILED_TO_READ },
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
          display_content = { FAILED_TO_READ },
          kind = "failed",
        })
        return
      end

      -- Calculate actual range
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

      local display_content
      if not is_memory then
        if args.offset or args.limit then
          display_content = string.format(
            "📖 Read lines %d-%d from %s",
            start_line,
            end_line,
            vim.fn.fnamemodify(args.path, ":.")
          )
        else
          display_content = string.format(
            "📖 Read %s (%d lines)",
            vim.fn.fnamemodify(args.path, ":."),
            #content
          )
        end
      else
        local memory_name = utils.format_memory_name(args.path)
        display_content =
          string.format("🧠 Remembered %s (%d lines)", memory_name, #content)
      end

      local outdated_message
      if args.offset or args.limit then
        local span = start_line ~= end_line
            and string.format("lines %d-%d", start_line, end_line)
          or string.format("line %d", start_line)
        outdated_message = string.format(
          "Previously read %s from %s - file was modified, use read tool to get current content",
          span,
          vim.fn.fnamemodify(args.path, ":.")
        )
      else
        local span = end_line > 1 and string.format("lines %d-%d", start_line, end_line)
          or string.format("line %d", start_line)
        outdated_message = string.format(
          "Previously read %s from %s - file was modified, use read tool to get current content",
          span,
          vim.fn.fnamemodify(args.path, ":.")
        )
      end

      callback({
        content = content,
        context = {
          buf = buf,
          pos = pos,
          tick = tracker.ensure_tracked(buf),
          outdated_message = outdated_message,
        },
        kind = "context",
        display_content = { display_content },
      })
    end,
  })
end)
