local diff = require("sia.diff")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local tool_utils = require("sia.tools.utils")

local failed_matches = {}
local MAX_FAILED_MATCHES = 3
local FAILED_TO_EDIT = "❌ Failed to edit"
local FAILED_TO_EDIT_FILE = "❌ Failed to edit %s"

local clear_outdated_tool_input =
  tool_utils.gen_clear_outdated_tool_input({ "old_string", "new_string" })

--- @param filename string
--- @param pos [integer, integer]
--- @return string
local function create_outdated_message(filename, pos)
  local same_line = pos[1] ~= pos[2]
  return string.format(
    "Previously edited %s, changing line%s %s",
    vim.fn.fnamemodify(filename, ":."),
    same_line and "s" or "",
    same_line and pos[1] .. " to " .. pos[2] or pos[1]
  )
end

--- Validate required arguments
--- @param args table
--- @return string? message
local function validate_args(args)
  if not args.target_file then
    return "Error: No target_file was provided"
  end

  if not args.old_string then
    return "Error: No old_string was provided"
  end

  if not args.new_string then
    return "Error: No new_string was provided"
  end
end

--- Ensure memory directory and buffer exist
--- @param target_file string
--- @return integer|nil buf
--- @return boolean is_memory
local function setup_target_file(target_file)
  local is_memory = utils.is_memory(target_file)
  if is_memory then
    local memory_dir = utils.get_memory_root(target_file)
    local stat = vim.uv.fs_stat(memory_dir)
    if not stat then
      vim.fn.mkdir(memory_dir, "p")
    end
  end

  local buf = utils.ensure_file_is_loaded(target_file, { listed = not is_memory })
  return buf, is_memory
end

--- Create display description for a successful edit
--- @param target_file string
--- @param pos [integer, integer]
--- @param col_span table|nil
--- @param is_memory boolean
--- @param fuzzy boolean
--- @return string
local function create_display_description(target_file, pos, col_span, is_memory, fuzzy)
  if is_memory then
    local memory_name = utils.format_memory_name(target_file)
    return string.format("🧠 Updated %s", memory_name)
  end

  local fuzzy_suffix = fuzzy and " - please double-check the changes" or ""

  if col_span then
    return string.format(
      "✏️ Edited line %d (columns %d-%d) in %s%s",
      pos[1],
      col_span[1],
      col_span[2],
      target_file,
      fuzzy_suffix
    )
  end

  local edit_span = pos[1] ~= pos[2] and string.format("lines %d-%d", pos[1], pos[2])
    or string.format("line %d", pos[1])

  return string.format("✏️ Edited %s in %s%s", edit_span, target_file, fuzzy_suffix)
end

--- Execute the actual buffer edit
--- @param buf integer
--- @param match sia.matcher.Match
--- @param new_text_lines string[]
--- @param is_memory boolean
--- @param conversation_id integer
local function execute_edit(buf, match, new_text_lines, is_memory, conversation_id)
  if not is_memory then
    diff.update_baseline(buf)
  end

  tracker.without_tracking(buf, conversation_id, function()
    local span = match.span
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

  if not is_memory then
    diff.update_reference(buf)
  end
end

--- Extract old span lines from the buffer content
--- @param old_content string[]
--- @param span [integer,integer]
--- @param col_span [integer, integer]?
--- @return string[]
local function get_old_span_lines(old_content, span, col_span)
  if col_span then
    return { old_content[span[1]] }
  end

  local lines = {}
  for i = span[1], span[2] do
    table.insert(lines, old_content[i])
  end
  return lines
end

--- Create the edit description for user prompt
--- @param target_file string
--- @param span [integer,integer]
--- @param col_span [integer,integer]?
--- @return string
local function create_edit_description(target_file, span, col_span)
  if col_span then
    return string.format(
      "Edit line %d (columns %d-%d) in %s",
      span[1],
      col_span[1],
      col_span[2],
      target_file
    )
  end

  local line_description = span[1] == span[2] and string.format("line %d", span[1])
    or string.format("lines %d-%d", span[1], span[2])

  return string.format("Edit %s in %s", line_description, target_file)
end

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
    if utils.is_memory(args.target_file) then
      return 1
    end
    return conversation.auto_confirm_tools["edit"]
  end,
}, function(args, conversation, callback, opts)
  local validation_message = validate_args(args)
  if validation_message then
    callback({
      content = { validation_message },
      display_content = { FAILED_TO_EDIT },
      kind = "failed",
    })
    return
  end

  local buf, is_memory = setup_target_file(args.target_file)
  if not buf then
    callback({
      content = { "Error: Cannot load " .. args.target_file },
      display_content = { FAILED_TO_EDIT },
      kind = "failed",
    })
    return
  end

  if failed_matches[buf] == nil then
    failed_matches[buf] = 0
  end
  local filename = vim.fn.fnamemodify(args.target_file, ":.")
  local matching = require("sia.matcher")
  local old_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  matching.find_best_match(args.old_string, old_content, function(result)
    if #result.matches == 1 then
      failed_matches[buf] = 0
      local match = result.matches[1]
      local span = match.span
      local edit_description =
        create_edit_description(args.target_file, span, match.col_span)

      opts.user_input(edit_description, {
        preview = function(preview_buf)
          local unified_diff =
            vim.split(utils.create_unified_diff(args.old_string, args.new_string, {
              old_start = span[1],
              new_start = span[1],
            }) or "", "\n")
          if #unified_diff == 0 then
            return nil
          end
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, unified_diff)
          vim.bo[preview_buf].ft = "diff"
          return #unified_diff
        end,
        on_accept = function()
          local old_span_lines = get_old_span_lines(old_content, span, match.col_span)

          local new_text_lines = result.strip_line_number
              and matching.strip_line_numbers(args.new_string)
            or vim.split(args.new_string, "\n")

          execute_edit(buf, match, new_text_lines, is_memory, conversation.id)

          local edit_start = span[1]
          local edit_end = span[1] + #new_text_lines - 1

          local old_text = table.concat(old_span_lines, "\n")
          local new_text = table.concat(new_text_lines, "\n")
          local unified_diff = utils.create_unified_diff(old_text, new_text, {
            old_start = span[1],
            new_start = edit_start,
            ctxlen = 3,
          })

          local diff_lines = vim.split(unified_diff or "", "\n")
          local success_msg = string.format(
            "Edited %s%s:",
            args.target_file,
            result.fuzzy and " (the match was not perfect)" or ""
          )
          table.insert(diff_lines, 1, success_msg)

          local pos = { edit_start, edit_end }
          local display_description = create_display_description(
            filename,
            pos,
            match.col_span,
            is_memory,
            result.fuzzy
          )

          callback({
            content = diff_lines,
            context = {
              buf = buf,
              pos = pos,
              tick = tracker.ensure_tracked(buf, { id = conversation.id, pos = pos }),
              outdated_message = create_outdated_message(filename, pos),
              clear_outdated_tool_input = clear_outdated_tool_input,
            },
            kind = "edit",
            display_content = { display_description },
          })
        end,
      })
    else
      failed_matches[buf] = failed_matches[buf] + 1
      local match_description = #result.matches == 0 and "no matches"
        or "multiple matches"

      if failed_matches[buf] >= MAX_FAILED_MATCHES then
        callback({
          kind = "failed",
          content = {
            string.format(
              "Failed to edit %s because %s were found. Show the location(s) and the edit you want to make and let the user manually make the change.",
              args.target_file,
              match_description
            ),
          },
          display_content = {
            string.format(FAILED_TO_EDIT_FILE, filename),
          },
        })
      else
        callback({
          kind = "failed",
          content = {
            string.format(
              "Failed to edit %s since I couldn't find the exact text to replace (found %s%s instead of exactly one).",
              args.target_file,
              match_description,
              result.fuzzy and " with fuzzy matching" or ""
            ),
          },
          display_content = {
            string.format(FAILED_TO_EDIT_FILE, filename),
          },
        })
      end
    end
  end, 50)
end)
