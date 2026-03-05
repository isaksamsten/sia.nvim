local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons
local diff = require("sia.diff")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local patch_mod = require("sia.patch")

--- Lark grammar for the apply_patch format used by OpenAI Codex models.
local APPLY_PATCH_GRAMMAR = [[
start: begin_patch hunk+ end_patch
begin_patch: "*** Begin Patch" LF
end_patch: "*** End Patch" LF?

hunk: add_hunk | delete_hunk | update_hunk
add_hunk: "*** Add File: " filename LF add_line+
delete_hunk: "*** Delete File: " filename LF
update_hunk: "*** Update File: " filename LF change_move? change?

filename: /(.+)/
add_line: "+" /(.*)/ LF -> line

change_move: "*** Move to: " filename LF
change: (change_context | change_line)+ eof_line?
change_context: ("@@" | "@@ " /(.+)/) LF
change_line: ("+" | "-" | " ") /(.*)/ LF
eof_line: "*** End of File" LF

%import common.LF
]]

--- Read content from a buffer.
--- @param buf integer
--- @return string
local function read_buf(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- Write content to a buffer and save to disk.
--- @param buf integer
--- @param content string
--- @param conversation_id integer
--- @param turn_id string?
local function write_buf(buf, content, conversation_id, turn_id)
  local lines = vim.split(content, "\n", { plain = true })
  diff.update_baseline(buf, { turn_id = turn_id })
  tracker.without_tracking(buf, conversation_id, function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_call(buf, function()
      pcall(vim.cmd, "noa silent write!")
    end)
  end)
  diff.update_reference(buf)
end

--- Delete a file and wipe its buffer.
--- @param path string
local function remove_file(path)
  local abs = vim.fn.fnamemodify(path, ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(b), ":p")
      if name == abs then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end
  vim.fn.delete(path)
end

--- Build a human-readable summary of a commit.
--- @param commit table
--- @return string[]
local function summarize_commit(commit)
  local summary = {}
  for path, change in pairs(commit) do
    local rel = vim.fn.fnamemodify(path, ":.")
    if change.type == "add" then
      table.insert(summary, string.format("%s Created %s", icons.save, rel))
    elseif change.type == "delete" then
      table.insert(summary, string.format("%s Deleted %s", icons.delete, rel))
    elseif change.type == "update" then
      if change.move_path then
        local dest_rel = vim.fn.fnamemodify(change.move_path, ":.")
        table.insert(
          summary,
          string.format("%s Moved %s → %s", icons.rename, rel, dest_rel)
        )
      else
        table.insert(summary, string.format("%s Updated %s", icons.edit, rel))
      end
    end
  end
  return summary
end

return tool_utils.new_tool({
  name = "apply_diff",
  message = "Applying diff...",
  description = "Apply a patch to files. This is a FREEFORM tool — output the patch directly, do NOT wrap it in JSON.",
  system_prompt = [[Use the `apply_diff` tool to make changes to existing files.

This tool uses a structured patch format with the following syntax:

*** Begin Patch
*** Update File: path/to/file.lua
@@
 context line (unchanged)
-old line to remove
+new line to add
 context line (unchanged)
*** End Patch

Rules:
- Lines starting with " " (space) are context lines that must match the existing file.
- Lines starting with "-" are removed from the file.
- Lines starting with "+" are added to the file.
- Use "*** Add File: path" to create a new file (all lines start with "+").
- Use "*** Delete File: path" to delete a file.
- Use "*** Move to: newpath" after "*** Update File:" to rename/move a file.
- Use "@@" to start a new hunk within the same file.
- Use "@@ <line content>" to skip ahead to a specific line in the file.
- Use "*** End of File" to indicate the patch extends to the end of the file.
- Multiple files can be patched in a single patch block.

IMPORTANT: Output the patch directly. Do NOT wrap it in JSON or code fences.]],
  custom = {
    format = {
      type = "grammar",
      syntax = "lark",
      definition = APPLY_PATCH_GRAMMAR,
    },
  },
  auto_apply = function(args, conversation)
    return conversation.auto_confirm_tools["apply_diff"]
  end,
}, function(args, conversation, callback, opts)
  local raw_input = args._raw_input
  if not raw_input or raw_input == "" then
    callback({
      content = { "Error: No patch input received" },
      display_content = icons.error .. " No patch input",
      kind = "failed",
    })
    return
  end

  local paths = patch_mod.identify_files_needed(raw_input)
  local orig = {}
  local bufs = {}
  for _, path in ipairs(paths) do
    local buf = utils.ensure_file_is_loaded(path, { listed = true })
    if buf then
      bufs[path] = buf
      orig[path] = read_buf(buf)
    end
  end

  local ok, patch_or_err, fuzz = pcall(patch_mod.text_to_patch, raw_input, orig)
  if not ok then
    callback({
      content = { "Error parsing patch: " .. tostring(patch_or_err) },
      display_content = icons.error .. " Failed to parse patch",
      kind = "failed",
    })
    return
  end
  local patch = patch_or_err

  local commit_ok, commit_or_err = pcall(patch_mod.patch_to_commit, patch, orig)
  if not commit_ok then
    callback({
      content = { "Error applying patch: " .. tostring(commit_or_err) },
      display_content = icons.error .. " Failed to apply patch",
      kind = "failed",
    })
    return
  end
  local commit = commit_or_err

  local display_lines = summarize_commit(commit)
  local change_count = vim.tbl_count(commit)
  if change_count == 0 then
    callback({
      content = { "Patch produced no changes." },
      display_content = icons.edit .. " No changes to apply",
    })
    return
  end

  local prompt = string.format(
    "Apply patch (%d file%s)",
    change_count,
    change_count > 1 and "s" or ""
  )

  opts.user_input(prompt, {
    preview = function(preview_buf)
      local preview_lines = {}
      for path, change in pairs(commit) do
        if change.type == "update" or change.type == "add" then
          local old_text = change.old_content or ""
          local new_text = change.new_content or ""
          local unified = utils.create_unified_diff(old_text, new_text, {
            old_start = 1,
            new_start = 1,
          })
          if unified and unified ~= "" then
            table.insert(preview_lines, "--- orig/" .. path)
            table.insert(preview_lines, "+++ ai/" .. (change.move_path or path))
            for _, l in ipairs(vim.split(unified, "\n")) do
              table.insert(preview_lines, l)
            end
            table.insert(preview_lines, "")
          end
        elseif change.type == "delete" then
          table.insert(preview_lines, "--- orig/" .. path)
          table.insert(preview_lines, "+++ /dev/null")
          table.insert(preview_lines, "")
        end
      end
      if #preview_lines == 0 then
        return nil
      end
      vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, preview_lines)
      vim.bo[preview_buf].ft = "diff"
      return #preview_lines
    end,
    on_accept = function()
      for path, change in pairs(commit) do
        if change.type == "delete" then
          remove_file(path)
        elseif change.type == "add" then
          local parent = vim.fn.fnamemodify(path, ":h")
          if parent ~= "" and parent ~= "." then
            vim.fn.mkdir(parent, "p")
          end
          local buf = utils.ensure_file_is_loaded(path, { listed = true })
          if buf then
            write_buf(buf, change.new_content, conversation.id, opts.turn_id)
          end
        elseif change.type == "update" then
          if change.move_path then
            local parent = vim.fn.fnamemodify(change.move_path, ":h")
            if parent ~= "" and parent ~= "." then
              vim.fn.mkdir(parent, "p")
            end
            local move_buf =
              utils.ensure_file_is_loaded(change.move_path, { listed = true })
            if move_buf then
              write_buf(move_buf, change.new_content, conversation.id, opts.turn_id)
            end
            remove_file(path)
          else
            local buf = bufs[path]
            if buf then
              write_buf(buf, change.new_content, conversation.id, opts.turn_id)
            end
          end
        end
      end

      local content_lines = {}
      table.insert(
        content_lines,
        string.format(
          "Patch applied successfully (%d file%s changed):",
          change_count,
          change_count > 1 and "s" or ""
        )
      )
      for _, dl in ipairs(display_lines) do
        table.insert(content_lines, dl)
      end

      callback({
        content = content_lines,
        display_content = table.concat(display_lines, "\n"),
        kind = "edit",
      })
    end,
  })
end)
