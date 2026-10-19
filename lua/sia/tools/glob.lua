local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")

local MAX_FILES_RESULT = 100
local MAX_FILES_SORT = 1000

--- Group the selected files for chat without changing their model-facing order.
--- @param files string[]
--- @return sia.ToolPreview
local function build_preview(files)
  local groups = {}
  for _, file in ipairs(files) do
    local path = file:gsub("/+$", "")
    local directory, name = path:match("^(.*)/([^/]+)$")
    directory = directory and (directory .. "/") or "./"
    name = name or path
    if file:sub(-1) == "/" then
      name = name .. "/"
    end
    groups[directory] = groups[directory] or {}
    table.insert(groups[directory], name)
  end
  local directories = vim.tbl_keys(groups)
  table.sort(directories)
  local lines = {}
  for _, directory in ipairs(directories) do
    if #lines > 0 then
      table.insert(lines, "")
    end
    table.insert(lines, directory)
    table.sort(groups[directory])
    for _, name in ipairs(groups[directory]) do
      table.insert(lines, "  " .. name)
    end
  end
  return { text = table.concat(lines, "\n"), ft = "text" }
end

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = "glob",
    description = "Find files matching a glob pattern in the current project",
    parameters = {
      pattern = {
        type = "string",
        description = "Glob pattern to match files (e.g., `*.lua`, `**/*.py`, `src/**`). If not provided, lists all files.",
      },
      path = {
        type = "string",
        description = "Directory path to search within (e.g., `src/lua`). If not provided, searches from current directory.",
      },
      hidden = {
        type = "boolean",
        description = "Include hidden files",
      },
    },
    required = {},
  },
  read_only = true,
  instructions = [[- Fast file pattern matching tool that works with any codebase size
- Supports glob patterns like "**/*.js" or "src/**/*.ts"
- Returns matching file paths sorted by modification time
- Use this tool when you need to find files by name patterns
- When you are doing an open ended search that may require multiple rounds of globbing
  and grepping, use the Agent tool instead
- You can call multiple tools in a single response. It is always better to speculatively
  perform multiple searches in parallel if they are potentially useful.]],
  summary = function(args)
    return "Exploring " .. "`" .. (args.path or ".") .. "`..."
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
}, function(args, conversation, callback, opts)
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
      local cmd = { "fd", "--print0" }

      if pattern and pattern ~= "" then
        table.insert(cmd, "--glob")
        -- When pattern contains a path separator, fd needs --full-path
        -- to match against the full relative path instead of just the filename.
        -- We also prepend **/ if not already present so it matches anywhere
        -- in the directory tree.
        if pattern:find("/") then
          table.insert(cmd, "--full-path")
          if not pattern:match("^%*%*/") and not pattern:match("^/") then
            pattern = "**/" .. pattern
          end
        end
        table.insert(cmd, pattern)
      elseif path and path ~= "" then
        -- When path is provided without pattern, use match-all pattern
        table.insert(cmd, ".")
      end

      if args.hidden then
        table.insert(cmd, "--hidden")
      end

      -- Add path as the last argument if provided
      if path and path ~= "" then
        table.insert(cmd, path)
      end

      local function failed(message)
        callback({
          content = "Error: " .. message,
          ephemeral = true,
        })
      end
      local ok, err = pcall(
        vim.system,
        cmd,
        { text = true, cwd = conversation.workspace },
        function(obj)
          if obj.code ~= 0 then
            local message = vim.trim(obj.stderr or "")
            failed(message ~= "" and message or "File search command failed.")
            return
          end

          local files = vim.split(obj.stdout or "", "\0", { trimempty = true })
          if #files == 0 then
            local msg
            if pattern and path then
              msg = string.format(
                "No files found matching pattern: %s in %s",
                pattern,
                path
              )
            elseif pattern then
              msg = "No files found matching pattern: " .. pattern
            elseif path then
              msg = "No files found in " .. path
            else
              msg = "No files found."
            end
            callback({ content = msg })
            return
          end

          local limited_files, total_count = utils.limit_files(
            files,
            { max_count = MAX_FILES_RESULT, max_sort = MAX_FILES_SORT }
          )

          local preview = build_preview(limited_files)

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

          callback({
            content = table.concat(limited_files, "\n"),
            summary = "Explored " .. "`" .. (path or ".") .. "`",
            preview = preview,
          })
        end
      )
      if not ok then
        failed(tostring(err))
      end
    end,
  })
end)
