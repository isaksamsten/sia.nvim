local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")

local FAILED_TO_REMOVE = "❌ Failed to remove file"

local function rel(path)
  return vim.fn.fnamemodify(path, ":.")
end

local function delete_buffers_under(path_abs)
  local abs = vim.fn.fnamemodify(path_abs, ":p")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        local nabs = vim.fn.fnamemodify(name, ":p")
        if nabs == abs or vim.startswith(nabs, abs .. "/") then
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
    end
  end
end

return tool_utils.new_tool({
  name = "remove_file",
  message = function(args)
    return string.format("Removing %s...", args.path or "")
  end,
  description = "Remove a file.",
  system_prompt = [[Remove a file from the project.]],
  parameters = {
    path = { type = "string", description = "Path to remove" },
  },
  required = { "path" },
}, function(args, _, callback, opts)
  local cfg = require("sia.config").options.defaults.file_ops or {}
  local trash = cfg.trash ~= false
  local restrict_root = cfg.restrict_to_project_root ~= false
  local trash_dir_name = ".sia_trash"

  if not args.path then
    callback({
      content = { "Error: path is required" },
      display_content = { FAILED_TO_REMOVE },
      kind = "failed",
    })
    return
  end

  local target_abs = vim.fn.fnamemodify(args.path, ":p")
  local root = utils.detect_project_root(target_abs)
  if restrict_root and not utils.path_in_root(target_abs, root) then
    callback({
      content = { string.format("Error: Operation must stay within project root: %s", root) },
      display_content = { FAILED_TO_REMOVE },
      kind = "failed",
    })
    return
  end

  local st = vim.uv.fs_stat(target_abs)
  if not st then
    callback({
      content = { string.format("Error: Path not found: %s", args.path) },
      display_content = { FAILED_TO_REMOVE },
      kind = "failed",
    })
    return
  end
  if st.type == "directory" then
    callback({
      content = { "Error: Directory removal is disabled by config" },
      display_content = { FAILED_TO_REMOVE },
      kind = "failed",
    })
    return
  end

  local prompt
  if trash ~= false then
    prompt = string.format("Move to trash: %s", args.path)
  else
    prompt = string.format("Permanently delete: %s", args.path)
  end
  opts.user_input(prompt, {
    on_accept = function()
      if trash then
        local timestamp = os.date("%Y%m%d-%H%M%S")
        local trash_base = vim.fs.joinpath(root, trash_dir_name, timestamp)
        local relative_from_root = vim.fn.fnamemodify(target_abs, ":p"):gsub("^" .. vim.pesc(root) .. "/?", "")
        local trash_dest = vim.fs.joinpath(trash_base, relative_from_root)
        vim.fn.mkdir(vim.fn.fnamemodify(trash_dest, ":h"), "p")
        local ok, err = pcall(vim.uv.fs_rename, target_abs, trash_dest)
        if not ok then
          callback({
            content = { string.format("Error: Failed to move to trash: %s", err or "unknown error") },
            display_content = { FAILED_TO_REMOVE },
            kind = "failed",
          })
          return
        end

        delete_buffers_under(target_abs)
        callback({
          content = { string.format("Moved %s to trash at %s", rel(target_abs), rel(trash_dest)) },
          display_content = { string.format("🗑️ Moved %s to trash", rel(target_abs)) },
        })
        return
      else
        local ok = vim.fn.delete(target_abs, "f")
        if ok ~= 0 then
          callback({
            content = { string.format("Error: Failed to delete %s", args.path) },
            display_content = { FAILED_TO_REMOVE },
            kind = "failed",
          })
          return
        end
        delete_buffers_under(target_abs)
        callback({
          content = { string.format("Deleted %s", rel(target_abs)) },
          display_content = { string.format("🗑️ Deleted %s", rel(target_abs)) },
        })
        return
      end
    end,
  })
end)
