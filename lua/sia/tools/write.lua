local icons = require("sia.ui").icons

local diff = require("sia.diff")
local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")

local clear_tool_input = tool_utils.gen_clear_outdated_tool_input({ "content" })

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = "write",
    description = "Write complete file contents to a buffer",
    parameters = {
      path = { type = "string", description = "The file path to write to" },
      content = { type = "string", description = "The complete file content to write" },
    },
    required = { "path", "content" },
  },
  notification = function()
    return "Writing file..."
  end,
  instructions = [[Write complete file contents to a buffer.

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
  persist_allow = function(args)
    return tool_utils.path_allow_rules("path", args.path)
  end,
  auto_apply = function(args, conversation)
    return conversation.auto_confirm_tools["write"]
  end,
}, function(args, conversation, callback, opts)
  if not args.path then
    callback({
      content = "Error: No file path provided",
      summary = icons.error .. " Failed to write file",
      ephemeral = true,
    })
    return
  end

  if not args.content then
    callback({
      content = "Error: No content provided",
      summary = icons.error .. " Failed to write file",
      ephemeral = true,
    })
    return
  end
  local file_exists = vim.fn.filereadable(args.path) == 1
  local prompt = file_exists
      and string.format("Overwrite existing file %s with new content", args.path)
    or string.format("Create new file %s", args.path)
  opts.user_input(prompt, {
    preview = function(preview_buf)
      if file_exists then
        local existing_content = vim.fn.readfile(args.path)
        local old_text = table.concat(existing_content, "\n")
        local new_text = args.content

        local unified_diff = utils.create_unified_diff(old_text, new_text, {
          old_start = 1,
          new_start = 1,
        })

        if not unified_diff or unified_diff == "" then
          return nil
        end

        local diff_lines = vim.split(unified_diff, "\n")
        table.insert(diff_lines, 1, "+++ ai/" .. args.path)
        table.insert(diff_lines, 1, "--- orig/" .. args.path)
        vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, diff_lines)
        vim.bo[preview_buf].ft = "diff"
        return #diff_lines
      else
        local lines = vim.split(args.content, "\n", { plain = true })
        vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
        local ft = vim.filetype.match({ filename = args.path })
        if ft then
          vim.bo[preview_buf].ft = ft
        end

        return #lines
      end
    end,
    on_accept = function()
      -- Ensure parent directory exists
      local parent_dir = vim.fn.fnamemodify(args.path, ":h")
      if parent_dir ~= "" and parent_dir ~= "." then
        vim.fn.mkdir(parent_dir, "p")
      end

      local buf = utils.ensure_file_is_loaded(args.path, { listed = true })
      if not buf then
        callback({
          content = "Error: Cannot create buffer for " .. args.path,
          summary = icons.error .. " Failed to write file",
          ephemeral = true,
        })
        return
      end

      diff.update_baseline(buf, { turn_id = opts.turn_id })
      local lines = vim.split(args.content, "\n", { plain = true })
      conversation.tracker:suppress(buf, function()
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_buf_call(buf, function()
          pcall(vim.cmd, "noa silent write!")
        end)
      end)
      diff.update_reference(buf)

      local action = file_exists and "overwritten" or "created"
      local display_text = string.format(
        "%s %s %s (%d lines)",
        icons.save,
        file_exists and "Overwrote" or "Created",
        vim.fn.fnamemodify(args.path, ":."),
        #lines
      )
      callback({
        content = string.format("Successfully %s buffer for %s", action, args.path),
        region = {
          buf = buf,
          stale = {
            content = "File has changed since written, use view to view it again",
            input = clear_tool_input,
          },
        },
        summary = display_text,
      })
    end,
  })
end)
