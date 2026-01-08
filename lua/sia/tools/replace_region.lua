local diff = require("sia.diff")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local tool_utils = require("sia.tools.utils")

local FAILED_TO_REPLACE = "❌ Failed to replace region"

local clear_outdated_tool_input =
  tool_utils.gen_clear_outdated_tool_input({ "text", "start_line", "end_line" })

--- @param filename string
--- @param start_line integer
--- @param end_line integer
--- @return string
local function create_outdated_message(filename, start_line, end_line)
  local same_line = start_line == end_line
  return string.format(
    "Previously replaced %s %s in %s",
    same_line and "line" or "lines",
    same_line and tostring(start_line)
      or string.format("%d to %d", start_line, end_line),
    vim.fn.fnamemodify(filename, ":.")
  )
end

return tool_utils.new_tool({
  name = "replace_region",
  message = function(args)
    if args.target_file then
      return string.format("Replacing region in %s...", args.target_file)
    end
    return "Replacing region..."
  end,
  description = "Replace a line region in a file",
  system_prompt = [[Replace a region (start and end line, inclusive) in a file.

This tool allows you to replace a contiguous line region with new text.

IMPORTANT:
- Always read the current state of the file right before using this tool.
  This tool is line-based, so if the file changed, your start_line/end_line
  may be wrong and the edit will fail or affect the wrong text.

Notes:
- This tool is strict: start_line and end_line must refer to existing lines.
- If you need to append new content, use the insert tool instead.
- For search/replace, use the edit tool.
- For rewriting entire files, use the write tool.]],
  parameters = {
    target_file = {
      type = "string",
      description = "The file path to the file to modify",
    },
    start_line = {
      type = "integer",
      description = "The start line of the region to replace (1-based, inclusive)",
    },
    end_line = {
      type = "integer",
      description = "The end line of the region to replace (1-based, inclusive)",
    },
    text = {
      type = "string",
      description = "The replacement text (can be empty to delete the region)",
    },
  },
  required = { "target_file", "start_line", "end_line", "text" },
  auto_apply = function(args, conversation)
    return conversation.auto_confirm_tools["replace_region"]
  end,
}, function(args, conversation, callback, opts)
  if not args.target_file then
    callback({
      content = { "Error: No target_file was provided" },
      display_content = { FAILED_TO_REPLACE },
      kind = "failed",
    })
    return
  end

  if args.start_line == nil then
    callback({
      content = { "Error: No start_line was provided" },
      display_content = { FAILED_TO_REPLACE },
      kind = "failed",
    })
    return
  end

  if args.end_line == nil then
    callback({
      content = { "Error: No end_line was provided" },
      display_content = { FAILED_TO_REPLACE },
      kind = "failed",
    })
    return
  end

  if args.text == nil then
    callback({
      content = { "Error: No text was provided" },
      display_content = { FAILED_TO_REPLACE },
      kind = "failed",
    })
    return
  end

  local buf = utils.ensure_file_is_loaded(args.target_file, { listed = true })
  if not buf then
    callback({
      content = { "Error: Cannot load " .. args.target_file },
      display_content = { FAILED_TO_REPLACE },
      kind = "failed",
    })
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  local start_line = args.start_line
  local end_line = args.end_line

  if start_line < 1 then
    callback({
      content = { string.format("Error: start_line must be >= 1, got %d", start_line) },
      display_content = { FAILED_TO_REPLACE },
      kind = "failed",
    })
    return
  end

  if end_line < start_line then
    callback({
      content = {
        string.format(
          "Error: end_line must be >= start_line, got start_line=%d end_line=%d",
          start_line,
          end_line
        ),
      },
      display_content = { FAILED_TO_REPLACE },
      kind = "failed",
    })
    return
  end

  if start_line > line_count then
    callback({
      content = {
        string.format(
          "Error: start_line must be within the file (1-%d), got %d",
          line_count,
          start_line
        ),
      },
      display_content = { FAILED_TO_REPLACE },
      kind = "failed",
    })
    return
  end

  if end_line > line_count then
    callback({
      content = {
        string.format(
          "Error: end_line must be within the file (1-%d), got %d",
          line_count,
          end_line
        ),
      },
      display_content = { FAILED_TO_REPLACE },
      kind = "failed",
    })
    return
  end

  local new_lines
  if args.text == "" then
    new_lines = {}
  else
    new_lines = vim.split(args.text, "\n", { plain = true })
  end

  local replace_description =
    string.format("Replace lines %d-%d in %s", start_line, end_line, args.target_file)

  local filename = vim.fn.fnamemodify(args.target_file, ":.")

  opts.user_input(replace_description, {
    preview = function(preview_buf)
      local existing_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

      local context_lines = 3
      local preview_start = math.max(1, start_line - context_lines)
      local preview_end = math.min(#existing_lines, end_line + context_lines)

      local before_ctx = vim.list_slice(existing_lines, preview_start, preview_end)
      local before_text = table.concat(before_ctx, "\n")

      local after_ctx = {}
      for i = preview_start, start_line - 1 do
        table.insert(after_ctx, existing_lines[i])
      end
      for _, l in ipairs(new_lines) do
        table.insert(after_ctx, l)
      end
      for i = end_line + 1, preview_end do
        table.insert(after_ctx, existing_lines[i])
      end

      local after_text = table.concat(after_ctx, "\n")

      local unified_diff = utils.create_unified_diff(before_text, after_text, {
        old_start = preview_start,
        new_start = preview_start,
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
        vim.api.nvim_buf_set_lines(buf, start_line - 1, end_line, false, new_lines)
        vim.api.nvim_buf_call(buf, function()
          pcall(vim.cmd, "noa silent write!")
        end)
      end)
      diff.update_reference(buf)

      local edit_start = start_line
      local edit_end = start_line + #new_lines - 1

      local success_msg = string.format(
        "Replaced lines %d-%d in %s",
        start_line,
        end_line,
        args.target_file
      )

      local display_description = string.format(
        "✂️ Replaced lines %d-%d in %s",
        start_line,
        end_line,
        filename
      )

      callback({
        content = { success_msg },
        context = {
          buf = buf,
          pos = { edit_start, edit_end },
          clear_outdated_tool_input = clear_outdated_tool_input,
          outdated_message = create_outdated_message(filename, start_line, end_line),
        },
        kind = "edit",
        display_content = { display_description },
      })
    end,
  })
end)
