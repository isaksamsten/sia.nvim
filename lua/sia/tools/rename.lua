local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")

local FAILED_TO_RENAME = "❌ Failed to rename/move file"

return tool_utils.new_tool({
  name = "rename_file",
  message = function(args)
    return string.format("Renaming %s → %s...", args.src or "", args.dest or "")
  end,
  description = "Rename/move a file.",
  system_prompt = [[Rename or move a file within the project.

Notes:
- Only supports renaming files.]],
  parameters = {
    src = { type = "string", description = "Source file path" },
    dest = { type = "string", description = "Destination file path" },
  },
  required = { "src", "dest" },
  auto_apply = function(args, conversation)
    return conversation.auto_confirm_tools["rename_file"]
  end,
  confirm = function(args)
    return string.format("Rename %s → %s", args.src, args.dest)
  end,
}, function(args, _, callback, opts)
  local config = require("sia.config").options.defaults.file_ops or {}
  local create_dirs = config.create_dirs_on_rename ~= false
  local restrict_root = config.restrict_to_project_root ~= false

  if not args.src or not args.dest then
    callback({
      content = { "Error: src and dest are required" },
      display_content = { FAILED_TO_RENAME },
      kind = "failed",
    })
    return
  end

  local src_abs = vim.fn.fnamemodify(args.src, ":p")
  local dest_abs = vim.fn.fnamemodify(args.dest, ":p")
  local root = utils.detect_project_root(src_abs)

  if restrict_root then
    if
      not utils.path_in_root(src_abs, root) or not utils.path_in_root(dest_abs, root)
    then
      callback({
        content = {
          string.format("Error: Operation must stay within project root: %s", root),
        },
        display_content = { FAILED_TO_RENAME },
        kind = "failed",
      })
      return
    end
  end

  local stat = vim.uv.fs_stat(src_abs)
  if not stat then
    callback({
      content = { string.format("Error: Source not found: %s", args.src) },
      display_content = { FAILED_TO_RENAME },
      kind = "failed",
    })
    return
  end
  if stat.type ~= "file" then
    callback({
      content = { "Error: Only file renames are supported" },
      display_content = { FAILED_TO_RENAME },
      kind = "failed",
    })
    return
  end

  local dest_stat = vim.uv.fs_stat(dest_abs)
  if dest_stat then
    callback({
      content = {
        string.format(
          "Error: Destination exists and overwriting is not allowed: %s",
          args.dest
        ),
      },
      display_content = { FAILED_TO_RENAME },
      kind = "failed",
    })
    return
  end

  opts.user_input(string.format("Rename %s → %s", args.src, args.dest), {
    on_accept = function()
      if create_dirs then
        local parent = vim.fn.fnamemodify(dest_abs, ":h")
        if parent ~= "" then
          vim.fn.mkdir(parent, "p")
        end
      end

      local success, _, err_code = vim.uv.fs_rename(src_abs, dest_abs)

      if err_code == "EXDEV" then
        success = vim.uv.fs_copyfile(src_abs, dest_abs)
        if success then
          success = pcall(vim.fn.delete, src_abs)
        end
        if not success then
          pcall(vim.fn.delete, dest_abs)
        end
      end

      if not success then
        callback({
          content = {
            string.format("Error: Failed to rename: %s", err_code or "unknown error"),
          },
          display_content = { FAILED_TO_RENAME },
          kind = "failed",
        })
        return
      end

      for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
        if
          not (vim.api.nvim_buf_is_loaded(buf_id) and vim.bo[buf_id].buftype == "")
        then
          goto continue
        end

        local cur_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf_id), ":p")
        if cur_name ~= src_abs then
          goto continue
        end

        vim.api.nvim_buf_set_name(buf_id, vim.fn.fnamemodify(dest_abs, ":."))

        -- Force write to avoid the 'overwrite existing file' error message
        vim.api.nvim_buf_call(buf_id, function()
          pcall(vim.cmd, "silent! write! | edit")
        end)

        ::continue::
      end

      local function rel(path)
        return vim.fn.fnamemodify(path, ":.")
      end
      callback({
        content = {
          string.format("Successfully renamed %s → %s", rel(src_abs), rel(dest_abs)),
        },
        display_content = {
          string.format("📁 Renamed %s → %s", rel(src_abs), rel(dest_abs)),
        },
      })
    end,
  })
end)
