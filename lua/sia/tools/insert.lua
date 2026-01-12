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

IMPORTANT:
- Always read the current state of the file right before using this tool.
  This tool is line-based, so if the file changed, your start_line/end_line
  may be wrong and the edit will fail or affect the wrong text.

Use cases:
- Adding new imports or declarations at specific positions
- Inserting new functions or methods at a known location
- Adding content at the beginning or end of a file
- Inserting text when you know the exact line number but don't want to match surrounding context
- For search/replace, use the edit tool.
- For replacing regions use the replace_region.
- For rewriting entire files, use the write tool.]],
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

  if not conversation:is_buf_valid(buf) then
    callback({
      content = {
        "Error: the content is stale. Read the file again to ensure that it's up to date",
      },
      kind = "failed",
    })
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local insert_line = args.line

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
    preview = function(preview_buf)
      local existing_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      local context_lines = 3
      local start_line = math.max(1, insert_line - context_lines)
      local end_line = math.min(#existing_lines, insert_line + context_lines - 1)

      local before_context = vim.list_slice(existing_lines, start_line, end_line)
      local before_text = table.concat(before_context, "\n")

      local after_context = vim.list_slice(existing_lines, start_line, insert_line - 1)
      for _, line in ipairs(text_lines) do
        table.insert(after_context, line)
      end
      local remaining = vim.list_slice(existing_lines, insert_line, end_line)
      for _, line in ipairs(remaining) do
        table.insert(after_context, line)
      end
      local after_text = table.concat(after_context, "\n")

      local unified_diff = utils.create_unified_diff(before_text, after_text, {
        old_start = start_line,
        new_start = start_line,
        ctxlen = context_lines,
      })

      if not unified_diff or unified_diff == "" then
        return nil
      end

      local diff_lines = vim.split(unified_diff, "\n")
      vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, diff_lines)
      vim.bo[preview_buf].ft = "diff"
      return #diff_lines
    end,
    on_accept = function()
      diff.update_baseline(buf)
      tracker.without_tracking(buf, conversation.id, function()
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
      diff.update_reference(buf)

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
            edit_end - edit_start + 1
          ),
        },
        kind = "edit",
        display_content = { display_description },
      })
    end,
  })
end)
