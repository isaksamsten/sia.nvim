local FAILED_TO_WRITE = "❌ Failed to write file"

local diff = require("sia.diff")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "write",
  message = "Writing file...",
  description = "Write complete file contents to a buffer (creates new file or overwrites existing)",
  system_prompt = [[Write complete file contents to a buffer.

This tool is ideal for:
- Creating new files from scratch
- Making large changes where rewriting the entire file is simpler than search/replace
- When you needs to restructure significant portions of a file
- Generating configuration files, templates, or boilerplate code

The tool will:
- Create a new buffer for the file if it doesn't exist
- Load and overwrite the buffer if the file already exists

Use this tool when:
- Creating new files
- Making extensive changes (>50% of file content)
- The search/replace approach would be too complex or error-prone
- You want to ensure the entire file structure is correct

For small, targeted changes, prefer the edit tool instead.]],
  parameters = {
    path = { type = "string", description = "The file path to write to" },
    content = { type = "string", description = "The complete file content to write" },
  },
  required = { "path", "content" },
  auto_apply = function(args, conversation)
    local file = vim.fs.basename(args.path)
    if file == "AGENTS.md" then
      return 1
    end
    return conversation.auto_confirm_tools["write"]
  end,
}, function(args, _, callback, opts)
  if not args.path then
    callback({
      content = { "Error: No file path provided" },
      display_content = { FAILED_TO_WRITE },
    })
    return
  end

  if not args.content then
    callback({
      content = { "Error: No content provided" },
      display_content = { FAILED_TO_WRITE },
    })
    return
  end
  local prompt
  if vim.fn.filereadable(args.path) == 1 then
    prompt = string.format("Overwrite existing file %s with new content", args.path)
  else
    prompt = string.format("Create new file %s", args.path)
  end
  opts.user_input(prompt, {
    on_accept = function()
      local buf = utils.ensure_file_is_loaded(args.path)
      if not buf then
        callback({
          content = { "Error: Cannot create buffer for " .. args.path },
          display_content = { FAILED_TO_WRITE },
        })
        return
      end

      local initial_code = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local file_exists = #initial_code > 0 and initial_code[1] ~= ""

      local lines = vim.split(args.content, "\n", { plain = true })
      tracker.non_tracked_edit(buf, function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_buf_call(buf, function()
          pcall(vim.cmd, "noa silent write!")
        end)
      end)

      if file_exists then
        diff.highlight_diff_changes(buf, initial_code)
      end

      local action = file_exists and "overwritten" or "created"
      local display_text = string.format(
        "%s %s (%d lines)",
        file_exists and "Overwrote" or "Created",
        vim.fn.fnamemodify(args.path, ":."),
        #lines
      )
      callback({
        content = { string.format("Successfully %s buffer for %s", action, args.path) },
        context = {
          buf = buf,
          kind = "edit",
          tick = tracker.ensure_tracked(buf),
          outdated_message = string.format(
            "%s %s",
            file_exists and "Overwrote" or "Created",
            vim.fn.fnamemodify(args.target_file, ":.")
          ),
        },
        display_content = { "💾 " .. display_text },
      })
    end,
  })
end)
