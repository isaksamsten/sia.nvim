local utils = require("sia.utils")
local tracker = require("sia.tracker")
local tool_utils = require("sia.tools.utils")

local FAILED_TO_READ = "❌ Failed to read"

return tool_utils.new_tool({
  name = "read",
  read_only = true,
  message = "Reading file contents...",
  system_prompt = [[Reads a file from the local filesystem. By default, it reads up to 2000 lines starting from the beginning of the file. You can optionally specify a line offset and limit (especially handy for long files), but it`s recommended to read the whole file by not providing these parameters. Any lines longer than 2000 characters will be truncated.]],
  description = [[Reads a file from the local filesystem.]],
  parameters = {
    path = { type = "string", description = "The file path" },
    offset = { type = "integer", description = "Line offset to start reading from (1-based, optional)" },
    limit = { type = "integer", description = "Maximum number of lines to read (default: 2000)" },
  },
  required = { "path" },
  auto_apply = function(args, _)
    local file = vim.fs.basename(args.path)
    if file == "AGENTS.md" then
      return 1
    end
    return nil
  end,
  confirm = function(args)
    local limit = args.limit or 2000
    if args.offset then
      return string.format(
        "Add lines %d-%d from %s to the conversation",
        args.offset,
        args.offset + limit - 1,
        args.path
      )
    end
    return string.format("Add %s to the conversation (up to %d lines)", args.path, limit)
  end,
}, function(args, _, callback)
  if not args.path then
    callback({
      content = { "Error: No file path was provided" },
      display_content = { FAILED_TO_READ },
    })
    return
  end

  if vim.fn.filereadable(args.path) == 0 then
    callback({
      content = { "Error: File cannot be found" },
      display_content = { FAILED_TO_READ },
    })
    return
  end

  local offset = args.offset or 1
  local limit = args.limit or 2000
  local max_line_length = 2000

  local buf = utils.ensure_file_is_loaded(args.path)
  local total_lines = vim.api.nvim_buf_line_count(buf)

  if offset > total_lines then
    callback({
      content = {
        string.format("Error: Offset %d is beyond end of file (file has %d lines)", offset, total_lines),
      },
      display_content = { FAILED_TO_READ },
    })
    return
  end

  -- Calculate actual range
  local start_line = math.max(1, offset)
  local end_line = math.min(total_lines, start_line + limit)

  local content =
    utils.get_content(buf, start_line - 1, end_line, { show_line_numbers = true, max_line_length = max_line_length })

  local pos = nil
  if args.offset or args.limit then
    pos = { offset, offset + #content - 1 }
  end

  local display_lines = {}
  if args.offset or args.limit then
    table.insert(
      display_lines,
      string.format("📖 Read lines %d-%d from %s", start_line, end_line, vim.fn.fnamemodify(args.path, ":."))
    )
  else
    table.insert(display_lines, string.format("📖 Read %s (%d lines)", vim.fn.fnamemodify(args.path, ":."), #content))
  end

  callback({
    content = content,
    context = {
      buf = buf,
      pos = pos,
      tick = tracker.ensure_tracked(buf),
      outdated_message = string.format("%s was modified externally", vim.fn.fnamemodify(args.path, ":.")),
    },
    kind = "context",
    display_content = display_lines,
  })
end)
