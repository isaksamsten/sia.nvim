local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")

local MAX_FILES_RESULT = 100
local MAX_FILES_SORT = 1000

return tool_utils.new_tool({
  name = "glob",
  read_only = true,
  system_prompt = [[- Find files matching glob patterns in the current project
- Supports standard glob patterns like `*.lua`, `**/*.py`, `src/**`
- Can search within specific directories using the path parameter
- Returns up to 100 files, sorted by modification time (newest first)
- Use this for file discovery, not for reading file contents
- For reading files, use the read tool after finding them with glob]],
  description = "Find files matching a glob pattern in the current project",
  message = "Searching for files...",
  parameters = {
    pattern = {
      type = "string",
      description = "Glob pattern to match files (e.g., `*.lua`, `**/*.py`, `src/**`). If not provided, lists all files.",
    },
    path = {
      type = "string",
      description = "Directory path to search within (e.g., `.sia/memory`, `src/lua`). If not provided, searches from current directory.",
    },
    hidden = {
      type = "boolean",
      description = "Include hidden files",
    },
  },
  required = {},
  auto_apply = function(args, conversation)
    if args.path and string.match(args.path, "%.sia/memory") then
      return 1
    end
    return conversation.auto_confirm_tools["glob"]
  end,
  confirm = function(args)
    local msg = ""
    if args.pattern then
      msg = "Find files matching pattern: " .. args.pattern
    else
      msg = "List all files"
    end
    if args.path then
      msg = msg .. " in " .. args.path
    end
    return msg
  end,
}, function(args, _, callback, opts)
  local prompt
  if args.pattern then
    prompt = "Find files matching pattern: " .. args.pattern
    if args.path then
      prompt = prompt .. " in " .. args.path
    end
  else
    prompt = args.path and ("List all files in " .. args.path)
      or "List all files in the current directory"
  end
  opts.user_input(prompt, {
    on_accept = function()
      local pattern = args.pattern
      local path = args.path
      local is_memory = path and string.match(path, "%.sia/memory")
      local cmd = { "fd", "--print0" }

      if pattern and pattern ~= "" then
        table.insert(cmd, "--glob")
        table.insert(cmd, pattern)
      elseif path and path ~= "" then
        -- When path is provided without pattern, use match-all pattern
        table.insert(cmd, ".")
      end

      if args.hidden or is_memory then
        table.insert(cmd, "--hidden")
      end

      -- Add path as the last argument if provided
      if path and path ~= "" then
        table.insert(cmd, path)
      end

      vim.system(cmd, { text = true }, function(obj)
        if obj.code ~= 0 then
          local msg
          if pattern and path then
            msg =
              string.format("No files found matching pattern: %s in %s", pattern, path)
          elseif pattern then
            msg = "No files found matching pattern: " .. pattern
          elseif path then
            msg = "No files found in " .. path
          else
            msg = "No files found (or fd is not installed)."
          end
          callback({ content = { msg } })
          return
        end

        local files = vim.split(obj.stdout or "", "\0", { trimempty = true })
        if #files == 0 then
          local msg
          if pattern and path then
            msg =
              string.format("No files found matching pattern: %s in %s", pattern, path)
          elseif pattern then
            msg = "No files found matching pattern: " .. pattern
          elseif path then
            msg = "No files found in " .. path
          else
            msg = "No files found."
          end
          callback({ content = { msg } })
          return
        end

        local limited_files, total_count = utils.limit_files(
          files,
          { max_count = MAX_FILES_RESULT, max_sort = MAX_FILES_SORT }
        )

        local header
        if pattern and path then
          header = string.format(
            "Files matching pattern `%s` in `%s` (max %d, newest first):",
            pattern,
            path,
            MAX_FILES_RESULT
          )
        elseif pattern then
          header = string.format(
            "Files matching pattern `%s` (max %d, newest first):",
            pattern,
            MAX_FILES_RESULT
          )
        elseif path then
          header = string.format(
            "Files in `%s` (max %d, newest first):",
            path,
            MAX_FILES_RESULT
          )
        else
          header = string.format(
            "Files in the current project (max %d, newest first):",
            MAX_FILES_RESULT
          )
        end
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

        local display_content
        if not is_memory then
          local display_line
          if pattern and path then
            display_content = string.format(
              "📂 Found %d files matching `%s` in `%s`",
              total_count,
              pattern,
              path
            )
          elseif pattern then
            display_content =
              string.format("📂 Found %d files matching `%s`", total_count, pattern)
          elseif path then
            display_content =
              string.format("📂 Found %d files in `%s`", total_count, path)
          else
            display_content = string.format("📂 Found %d files", total_count)
          end
          display_content = { display_line }
        else
          display_content = nil
        end

        callback({
          content = limited_files,
          display_content = display_content,
        })
      end)
    end,
  })
end)
