local FAILED_TO_WRITE = "❌ Failed to write file"

local diff = require("sia.diff")
local utils = require("sia.utils")
local tracker = require("sia.tracker")
local tool_utils = require("sia.tools.utils")

local clear_tool_input = tool_utils.gen_clear_outdated_tool_input({ "content" })

return tool_utils.new_tool({
  name = "write",
  message = "Writing file...",
  description = "Write complete file contents to a buffer",
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
    target_file = { type = "string", description = "The file path to write to" },
    content = { type = "string", description = "The complete file content to write" },
  },
  required = { "target_file", "content" },
  auto_apply = function(args, conversation)
    if utils.is_memory(args.target_file) then
      return 1
    end
    return conversation.auto_confirm_tools["write"]
  end,
}, function(args, _, callback, opts)
  if not args.target_file then
    callback({
      content = { "Error: No file path provided" },
      display_content = { FAILED_TO_WRITE },
      kind = "failed",
    })
    return
  end

  if not args.content then
    callback({
      content = { "Error: No content provided" },
      display_content = { FAILED_TO_WRITE },
      kind = "failed",
    })
    return
  end
  local is_memory = utils.is_memory(args.target_file)
  local file_exists = vim.fn.filereadable(args.target_file) == 1
  local prompt = file_exists
      and string.format("Overwrite existing file %s with new content", args.target_file)
    or string.format("Create new file %s", args.target_file)
  opts.user_input(prompt, {
    on_accept = function()
      local buf =
        utils.ensure_file_is_loaded(args.target_file, { listed = not is_memory })
      if not buf then
        callback({
          content = { "Error: Cannot create buffer for " .. args.target_file },
          display_content = { FAILED_TO_WRITE },
          kind = "failed",
        })
        return
      end

      if not is_memory then
        diff.update_baseline(buf)
      end
      local lines = vim.split(args.content, "\n", { plain = true })
      tracker.non_tracked_edit(buf, function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_buf_call(buf, function()
          pcall(vim.cmd, "noa silent write!")
        end)
      end)
      if not is_memory then
        diff.update_reference(buf)
      end

      local display_text
      local action = file_exists and "overwritten" or "created"
      if not is_memory then
        display_text = string.format(
          "💾 %s %s (%d lines)",
          file_exists and "Overwrote" or "Created",
          vim.fn.fnamemodify(args.target_file, ":."),
          #lines
        )
      else
        local memory_name = utils.format_memory_name(args.target_file)
        display_text = file_exists and string.format("🧠 Updated %s", memory_name)
          or string.format("🧠 Created %s", memory_name)
      end
      callback({
        content = {
          string.format("Successfully %s buffer for %s", action, args.target_file),
        },
        context = {
          buf = buf,
          kind = "edit",
          clear_outdated_tool_input = clear_tool_input,
        },
        display_content = { display_text },
      })
    end,
  })
end)
