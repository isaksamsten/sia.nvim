local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")

local MAX_FILES_RESULT = 100
local MAX_FILES_SORT = 1000

return tool_utils.new_tool({
  name = "glob",
  description = "Find files matching a glob pattern in the current project",
  message = "Searching for files...",
  parameters = {
    pattern = {
      type = "string",
      description = "Glob pattern to match files (e.g., `*.lua`, `**/*.py`, `src/**`). If not provided, lists all files.",
    },
    hidden = {
      type = "boolean",
      description = "Include hidden files",
    },
  },
  required = {},
  confirm = function(args)
    if args.pattern then
      return "Find files matching pattern: " .. args.pattern
    else
      return "List all files in the current directory"
    end
  end,
}, function(args, _, callback, opts)
  local prompt
  if args.pattern then
    prompt = "Find files matching pattern: " .. args.pattern
  else
    prompt = "List all files in the current directory"
  end
  opts.user_input(prompt, {
    on_accept = function()
      local cmd = { "fd", "--type", "f", "--print0" }
      local pattern = args.pattern

      if pattern and pattern ~= "" then
        table.insert(cmd, "--glob")
        table.insert(cmd, pattern)
      end

      if args.hidden then
        table.insert(cmd, "--hidden")
      end

      vim.system(cmd, { text = true }, function(obj)
        if obj.code ~= 0 then
          local msg = pattern and ("No files found matching pattern: " .. pattern)
            or "No files found (or fd is not installed)."
          callback({ content = { msg } })
          return
        end

        local files = vim.split(obj.stdout or "", "\0", { trimempty = true })
        if #files == 0 then
          local msg = pattern and ("No files found matching pattern: " .. pattern)
            or "No files found."
          callback({ content = { msg } })
          return
        end

        local limited_files, total_count = utils.limit_files(
          files,
          { max_count = MAX_FILES_RESULT, max_sort = MAX_FILES_SORT }
        )

        local header = pattern
            and ("Files matching pattern `" .. pattern .. "` (max " .. MAX_FILES_RESULT .. ", newest first):")
          or (
            "Files in the current project (max "
            .. MAX_FILES_RESULT
            .. ", newest first):"
          )
        table.insert(limited_files, 1, header)

        if total_count > MAX_FILES_RESULT then
          table.insert(
            limited_files,
            2,
            string.format(
              "Showing %d of %d files (limited to most recent %d)",
              MAX_FILES_RESULT,
              total_count,
              MAX_FILES_RESULT
            )
          )
        end

        callback({
          content = limited_files,
          display_content = {
            pattern and string.format(
              "📂 Found %d files matching `%s`",
              total_count,
              pattern
            ) or string.format("📂 Found %d files", total_count),
          },
        })
      end)
    end,
  })
end)
