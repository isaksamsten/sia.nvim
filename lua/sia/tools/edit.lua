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

--- Create display description for a successful edit
--- @param target_file string
--- @param pos [integer, integer]
--- @param col_span table|nil
--- @param fuzzy boolean
--- @return string
local function create_display_description(target_file, pos, col_span, fuzzy)
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

--- Execute multiple edits in reverse order to maintain line numbers
--- @param buf integer
--- @param matches sia.matcher.Match[]
--- @param new_text_lines string[]
--- @param conversation_id integer
local function perform_replace_all(buf, matches, new_text_lines, conversation_id)
  local sorted_matches = matches
  if #matches > 1 then
    sorted_matches = vim.deepcopy(matches)
    table.sort(sorted_matches, function(a, b)
      if a.span[1] ~= b.span[1] then
        return a.span[1] > b.span[1]
      end
      if a.col_span and b.col_span then
        return a.col_span[1] > b.col_span[1]
      end
      return false
    end)
  end

  diff.update_baseline(buf)

  tracker.without_tracking(buf, conversation_id, function()
    for _, match in ipairs(sorted_matches) do
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
    end

    vim.api.nvim_buf_call(buf, function()
      pcall(vim.cmd, "noa silent write!")
    end)
  end)

  diff.update_reference(buf)
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
  system_prompt = [[Performs exact string replacements in files.

Usage:
- You must use your `read` tool at least once in the conversation before editing. This tool will error if you attempt an edit without reading the file.
- When editing text from Read tool output, ensure you preserve the exact indentation (tabs/spaces) as it appears AFTER the line number prefix. The line number prefix format is: spaces + line number + tab. Everything after that tab is the actual file content to match. Never include any part of the line number prefix in the old_string or new_string.
- ALWAYS prefer editing existing files in the codebase. NEVER write new files unless explicitly required.
- Only use emojis if the user explicitly requests it. Avoid adding emojis to files unless asked.
- The edit will FAIL if `old_string` is not unique in the file. Either provide a larger string with more surrounding context to make it unique or use `replace_all` to change every instance of `old_string`.
- Use `replace_all` for replacing and renaming strings across the file. This parameter is useful if you want to rename a variable for instance.]],
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
    replace_all = {
      type = "boolean",
      description = "If true, replace all occurrences of old_string in the file. If false or omitted, only replace a single unique occurrence.",
    },
  },
  required = { "target_file", "old_string", "new_string" },
  auto_apply = function(args, conversation)
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

  local buf = utils.ensure_file_is_loaded(args.target_file, { listed = true })
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
  local replace_all = args.replace_all == true

  matching.find_best_match(args.old_string, old_content, replace_all, function(result)
    local num_matches = #result.matches

    -- When replace_all is true, we expect to find and replace all occurrences
    if replace_all and num_matches > 0 then
      failed_matches[buf] = 0

      local edit_description = string.format(
        "Replace all %d occurrence%s in %s",
        num_matches,
        num_matches > 1 and "s" or "",
        args.target_file
      )

      opts.user_input(edit_description, {
        preview = function(preview_buf)
          local all_diffs = {}

          for i, match in ipairs(result.matches) do
            if i > 1 then
              table.insert(all_diffs, "")
            end

            local span = match.span
            local unified_diff =
              vim.split(utils.create_unified_diff(args.old_string, args.new_string, {
                old_start = span[1],
                new_start = span[1],
              }) or "", "\n")

            for _, line in ipairs(unified_diff) do
              table.insert(all_diffs, line)
            end
          end

          if #all_diffs == 0 then
            return nil
          end
          vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, all_diffs)
          vim.bo[preview_buf].ft = "diff"
          return #all_diffs
        end,
        on_accept = function()
          local new_text_lines = result.strip_line_number
              and matching.strip_line_numbers(args.new_string)
            or vim.split(args.new_string, "\n")

          perform_replace_all(buf, result.matches, new_text_lines, conversation.id)

          local first_match = result.matches[1]
          local last_match = result.matches[#result.matches]
          local pos = { first_match.span[1], last_match.span[2] }

          local success_msg = string.format(
            "Replaced all %d occurrence%s in %s",
            num_matches,
            num_matches > 1 and "s" or "",
            args.target_file
          )

          local display_description = string.format(
            "✏️ Replaced all %d occurrence%s in %s",
            num_matches,
            num_matches > 1 and "s" or "",
            filename
          )

          callback({
            content = { success_msg },
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
    elseif num_matches == 1 and not replace_all then
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

          perform_replace_all(buf, { match }, new_text_lines, conversation.id)

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
          local display_description =
            create_display_description(filename, pos, match.col_span, result.fuzzy)

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
      local match_description = num_matches == 0 and "no matches" or "multiple matches"

      if replace_all and num_matches == 0 then
        callback({
          kind = "failed",
          content = {
            string.format(
              "Failed to edit %s with replace_all because no matches were found for old_string.",
              args.target_file
            ),
          },
          display_content = {
            string.format(FAILED_TO_EDIT_FILE, filename),
          },
        })
      elseif not replace_all and num_matches > 1 then
        callback({
          kind = "failed",
          content = {
            string.format(
              "Failed to edit %s because %d matches were found. Either provide more context to make old_string unique, or set replace_all to true to replace all %d occurrences.",
              args.target_file,
              num_matches,
              num_matches
            ),
          },
          display_content = {
            string.format(FAILED_TO_EDIT_FILE, filename),
          },
        })
      elseif failed_matches[buf] >= MAX_FAILED_MATCHES then
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
