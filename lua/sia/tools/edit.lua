local diff = require("sia.diff")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local tool_utils = require("sia.tools.utils")

local failed_matches = {}
local CHOICES = {
  "Apply changes immediately",
  "Apply changes immediately and remember this choice",
  "Apply changes and preview them in diff view",
}
local MAX_FAILED_MATCHES = 3
local FAILED_TO_EDIT = "❌ Failed to edit"
local FAILED_TO_EDIT_FILE = "❌ Failed to edit %s"

return tool_utils.new_tool({
  name = "edit",
  message = function(args)
    if args.target_file then
      return string.format("Making changes to %s...", args.target_file)
    end
    return "Making file changes..."
  end,
  description = "Tool for editing files",
  system_prompt = [[This is a tool for editing files.

Before using this tool:

1. Unless the file content is available, use the read tool to understand the
   file's contents and context

To make a file edit, provide the following:
1. file_path: The path to the file to modify
2. old_string: The text to replace (must be unique within the file, and must
   match the file contents exactly, including all whitespace and indentation)
3. new_string: The edited text to replace the old_string

The tool will replace ONE occurrence of old_string with new_string in the
specified file.

CRITICAL REQUIREMENTS FOR USING THIS TOOL:

1. UNIQUENESS: The old_string MUST uniquely identify the specific instance you
   want to change. This means:
  - Include AT LEAST 3-5 lines of context BEFORE the change point
  - Include AT LEAST 3-5 lines of context AFTER the change point
  - Include all whitespace, indentation, and surrounding code exactly as it appears in the file

2. SINGLE INSTANCE: This tool can only change ONE instance at a time. If you need to change multiple instances:
  - Make separate calls to this tool for each instance
  Each call must uniquely identify its specific instance using extensive context

3. VERIFICATION: Before using this tool:
  - Check how many instances of the target text exist in the file
  - If multiple instances exist, gather enough context to uniquely identify each one
  - Plan separate tool calls for each instance

WARNING: If you do not follow these requirements:
- The tool will fail if old_string matches multiple locations
- The tool will fail if old_string doesn't match exactly (including whitespace)
- You may change the wrong instance if you don't include enough context

When making edits:
- Ensure the edit results in idiomatic, correct code
- Do not leave the code in a broken state

If you want to create a new file, use:
- A new file path, including dir name if needed
- An empty old_string
- The new file's contents as new_string

MULTIPLE EDITS: When you need to make multiple changes to the same file, use
multiple parallel calls to this tool in a single message. Each call should handle
one specific change with clear, unique context.
```
]],
  parameters = {

    target_file = {
      type = "string",
      description = "The file path to the file to modify",
    },
    old_string = {
      type = "string",
      description = "The text to replace",
    },
    new_string = {
      type = "string",
      description = "The text to replace with",
    },
  },
  required = { "target_file", "old_string", "new_string" },
  auto_apply = function(args, conversation)
    local file = vim.fs.basename(args.target_file)
    if file == "AGENTS.md" then
      return 1
    end
    return conversation.auto_confirm_tools["edit"]
  end,
}, function(args, conversation, callback, opts)
  if not args.target_file then
    callback({
      content = { "Error: No target_file was provided" },
      display_content = { FAILED_TO_EDIT },
    })
    return
  end

  if not args.old_string then
    callback({ content = { "Error: No old_string was provided" }, display_content = { FAILED_TO_EDIT } })
    return
  end

  if not args.new_string then
    callback({
      content = { "Error: No new_string was provided" },
      display_content = { FAILED_TO_EDIT },
    })
    return
  end

  local buf = utils.ensure_file_is_loaded(args.target_file)
  if not buf then
    callback({
      content = { "Error: Cannot load " .. args.target_file },
      display_content = { FAILED_TO_EDIT },
    })
    return
  end
  local matching = require("sia.matcher")

  local old_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local best_matches = matching.find_best_match(args.old_string, old_content)

  if failed_matches[buf] == nil then
    failed_matches[buf] = 0
  end

  if #best_matches.matches == 1 then
    failed_matches[buf] = 0
    local match = best_matches.matches[1]
    local span = match.span

    opts.user_choice(string.format("Edit %s", args.target_file), {
      choices = CHOICES,
      on_accept = function(choice)
        local new_text_lines
        if best_matches.strip_line_number then
          new_text_lines = matching.strip_line_numbers(args.new_string)
        else
          new_text_lines = vim.split(args.new_string, "\n")
        end

        diff.init_change_tracking(buf)
        tracker.non_tracked_edit(buf, function()
          if match.col_span then
            vim.api.nvim_buf_set_text(
              buf,
              span[1] - 1,
              match.col_span[1] - 1,
              span[1] - 1,
              match.col_span[2],
              new_text_lines
            )
          else
            vim.api.nvim_buf_set_lines(buf, span[1] - 1, span[2], false, new_text_lines)
          end
          vim.api.nvim_buf_call(buf, function()
            pcall(vim.cmd, "noa silent write!")
          end)
        end)
        diff.update_reference_content(buf)
        if choice == 1 or choice == 2 then
          diff.highlight_diff_changes(buf)
          if choice == 2 then
            conversation.auto_confirm_tools["edit"] = 1
          end
        elseif choice == 3 then
          diff.show_diff_preview(buf)
        end

        local new_content_lines = vim.api.nvim_buf_line_count(buf)
        local context_lines = 4
        local start_context = math.max(1, span[1] - context_lines)

        local edit_start = span[1]
        local edit_end = span[1] + #new_text_lines - 1

        local end_context = math.min(new_content_lines, edit_end + context_lines)
        local snippet_lines = utils.get_content(buf, start_context - 1, end_context)

        local success_msg = string.format(
          "Successfully edited %s%s. Here`s the edited snippet as returned by cat -n:",
          args.target_file,
          best_matches.fuzzy and " (the match was not perfect)" or ""
        )
        table.insert(snippet_lines, 1, success_msg)
        local outdated_message, display_description
        if match.col_span then
          outdated_message = string.format(
            "Edited %s on line %d (columns %d-%d)",
            vim.fn.fnamemodify(args.target_file, ":."),
            edit_start,
            match.col_span[1],
            match.col_span[2]
          )
          display_description = string.format(
            "✏️ Edited line %d (columns %d-%d) in %s%s",
            edit_start,
            match.col_span[1],
            match.col_span[2],
            vim.fn.fnamemodify(args.target_file, ":."),
            best_matches.fuzzy and " - please double-check the changes" or ""
          )
        else
          local edit_span = edit_start ~= edit_end and string.format("lines %d-%d", edit_start, edit_end)
            or string.format("line %d", edit_start)
          outdated_message = string.format("Edited %s on %s", vim.fn.fnamemodify(args.target_file, ":."), edit_span)
          display_description = string.format(
            "✏️ Edited %s in %s%s",
            edit_span,
            vim.fn.fnamemodify(args.target_file, ":."),
            best_matches.fuzzy and " - please double-check the changes" or ""
          )
        end

        callback({
          content = snippet_lines,
          context = {
            buf = buf,
            pos = { edit_start, edit_end },
            tick = tracker.ensure_tracked(buf),
            outdated_message = outdated_message,
          },
          kind = "edit",
          display_content = { display_description },
        })
      end,
    })
  else
    failed_matches[buf] = failed_matches[buf] + 1
    local match_description = #best_matches.matches == 0 and "no matches" or "multiple matches"
    if failed_matches[buf] >= MAX_FAILED_MATCHES then
      callback({
        content = {
          string.format(
            "Edit failed because %s were found. Please show the location(s) and the edit you want to make and let the user manually make the change.",
            match_description
          ),
        },
        display_content = {
          string.format(FAILED_TO_EDIT_FILE, vim.fn.fnamemodify(args.target_file, ":.")),
        },
      })
    else
      callback({
        content = {
          string.format(
            "Failed to edit %s since I couldn't find the exact text to replace (found %s%s instead of exactly one).",
            args.target_file,
            match_description,
            best_matches.fuzzy and " with fuzzy matching" or ""
          ),
        },
        display_content = {
          string.format(FAILED_TO_EDIT_FILE, vim.fn.fnamemodify(args.target_file, ":.")),
        },
      })
    end
  end
end)
