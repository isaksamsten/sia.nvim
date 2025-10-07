local diff = require("sia.diff")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local tool_utils = require("sia.tools.utils")

local FAILED_TO_INSERT = "❌ Failed to insert"

local clear_outdated_tool_input = tool_utils.gen_clear_outdated_tool_input({ "text" })

--- @param filename string
--- @param start_edit integer
--- @param end_edit integer
--- @return string
local function create_outdated_message(filename, line, count)
  local multiple_lines = count > 1
  return string.format(
    "Previously inserted %d line%s at line %d in %s",
    count,
    multiple_lines and "s" or "",
    line,
    vim.fn.fnamemodify(filename, ":.")
  )
end

return tool_utils.new_tool({
  name = "insert",
  message = function(args)
    if args.target_file then
      return string.format("Inserting text into %s...", args.target_file)
    end
    return "Inserting text..."
  end,
  description = "Insert text at a specific line in a file",
  system_prompt = [[Insert text at a specific line in a file.

This tool allows you to insert new content at a specified line number without
needing to match existing text patterns.

To use this tool, provide:
1. target_file: The path to the file to modify
2. line: The line number where text should be inserted (1-based)
   - The text will be inserted BEFORE this line
   - Use line 1 to insert at the beginning
   - Use a line number beyond the file length to append to the end
3. text: The text content to insert

Use cases:
- Adding new imports or declarations at specific positions
- Inserting new functions or methods at a known location
- Adding content at the beginning or end of a file
- Inserting text when you know the exact line number but don't want to match surrounding context

Note: If you need to replace existing content, use the edit tool instead.
If you need to rewrite large portions of a file, use the write tool instead.]],
  parameters = {
    target_file = {
      type = "string",
      description = "The file path to the file to modify",
    },
    line = {
      type = "integer",
      description = "The line number where text should be inserted (1-based, text is inserted before this line)",
    },
    text = {
      type = "string",
      description = "The text content to insert",
    },
  },
  required = { "target_file", "line", "text" },
  auto_apply = function(args, conversation)
    local file = vim.fs.basename(args.target_file)
    if file == "AGENTS.md" then
      return 1
    end
    return conversation.auto_confirm_tools["insert"]
  end,
}, function(args, conversation, callback, opts)
  if not args.target_file then
    callback({
      content = { "Error: No target_file was provided" },
      display_content = { FAILED_TO_INSERT },
      kind = "failed",
    })
    return
  end

  if not args.line then
    callback({
      content = { "Error: No line number was provided" },
      display_content = { FAILED_TO_INSERT },
      kind = "failed",
    })
    return
  end

  if not args.text then
    callback({
      content = { "Error: No text was provided" },
      display_content = { FAILED_TO_INSERT },
      kind = "failed",
    })
    return
  end

  local buf = utils.ensure_file_is_loaded(args.target_file, { listed = true })
  if not buf then
    callback({
      content = { "Error: Cannot load " .. args.target_file },
      display_content = { FAILED_TO_INSERT },
      kind = "failed",
    })
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local insert_line = args.line

  -- Validate line number
  if insert_line < 1 then
    callback({
      content = {
        string.format("Error: Line number must be >= 1, got %d", insert_line),
      },
      display_content = { FAILED_TO_INSERT },
      kind = "failed",
    })
    return
  end

  if insert_line > line_count + 1 then
    insert_line = line_count + 1
  end

  local text_lines = vim.split(args.text, "\n", { plain = true })
  local insert_description = string.format(
    "Insert %d line%s at line %d in %s",
    #text_lines,
    #text_lines == 1 and "" or "s",
    insert_line,
    args.target_file
  )

  opts.user_input(insert_description, {
    on_accept = function()
      diff.init_change_tracking(buf)
      tracker.non_tracked_edit(buf, function()
        vim.api.nvim_buf_set_lines(
          buf,
          insert_line - 1,
          insert_line - 1,
          false,
          text_lines
        )
        vim.api.nvim_buf_call(buf, function()
          pcall(vim.cmd, "noa silent write!")
        end)
      end)
      diff.update_reference_content(buf)
      diff.update_and_highlight_diff(buf)

      local edit_start = insert_line
      local edit_end = insert_line + #text_lines - 1

      local success_msg = string.format(
        "Inserted %d line%s at line %d in %s",
        #text_lines,
        #text_lines == 1 and "" or "s",
        insert_line,
        args.target_file
      )

      local display_description = string.format(
        "📝 Inserted %d line%s at line %d in %s",
        #text_lines,
        #text_lines == 1 and "" or "s",
        insert_line,
        vim.fn.fnamemodify(args.target_file, ":.")
      )

      callback({
        content = { success_msg },
        context = {
          buf = buf,
          pos = { edit_start, edit_end },
          clear_outdated_tool_input = clear_outdated_tool_input,
          outdated_message = create_outdated_message(
            args.target_file,
            insert_line,
            edit_end - edit_start
          ),
        },
        kind = "edit",
        display_content = { display_description },
      })
    end,
  })
end)
