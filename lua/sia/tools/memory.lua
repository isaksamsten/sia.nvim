local tool_utils = require("sia.tools.utils")

return tool_utils.new_tool({
  name = "memory",
  system_prompt = [[
Manage agent memory.

Use this tool to:
- Keep track of progress on complex tasks.
- Store important information that shouldn't be lost if context is reset.
- Record learnings and solutions for future reference.
- Maintain a todo list or plan for the current session.

All paths MUST start with `/memories/`.
]],
  read_only = false,
  message = function(args)
    return string.format("Executing memory command: %s", args.command)
  end,
  description = "Manage agent memory (view, create, edit, delete, etc.)",
  parameters = {
    command = {
      type = "string",
      enum = { "view", "create", "str_replace", "insert", "delete", "rename", "search" },
      description = "The command to execute",
    },
    path = { type = "string", description = "Path to the memory file or directory" },
    old_path = { type = "string", description = "Old path for rename" },
    new_path = { type = "string", description = "New path for rename" },
    view_range = {
      type = "array",
      items = { type = "integer" },
      description = "Line range [start, end] for view",
    },
    file_text = { type = "string", description = "Content for create" },
    old_str = { type = "string", description = "Text to replace for str_replace" },
    new_str = { type = "string", description = "Replacement text for str_replace" },
    insert_line = { type = "integer", description = "Line number to insert at" },
    insert_text = { type = "string", description = "Text to insert" },
    query = { type = "string", description = "Search query" },
  },
  auto_apply = function(args, _)
    return 1
  end,
  required = { "command" },
}, function(args, _, callback, opts)
  local utils = require("sia.utils")
  local matcher = require("sia.matcher")
  local root = utils.detect_project_root(vim.fn.getcwd())
  local memory_dir = vim.fs.joinpath(root, ".sia", "memory")

  if vim.fn.isdirectory(memory_dir) == 0 then
    vim.fn.mkdir(memory_dir, "p")
  end

  local function resolve_path(p)
    if not p then
      return nil
    end
    -- Handle /memories/ prefix
    if vim.startswith(p, "/memories/") then
      p = string.sub(p, 11) -- remove /memories/
    elseif vim.startswith(p, "/memories") then
      p = string.sub(p, 10)
    end
    -- Remove leading slash if present after stripping prefix
    if vim.startswith(p, "/") then
      p = string.sub(p, 2)
    end

    local resolved = vim.fs.normalize(vim.fs.joinpath(memory_dir, p))
    if not vim.startswith(resolved, memory_dir) then
      return nil
    end
    return resolved
  end

  local path = resolve_path(args.path)

  -- Security: If a path was provided but rejected by resolve_path, fail.
  if args.path and not path then
    callback({
      content = { "Error: Invalid path" },
      kind = "failed",
    })
    return
  end
  --- @cast path string

  if args.command == "view" then
    if not path then
      -- Default to root memory dir if no path
      path = memory_dir
    end

    local stat = vim.loop.fs_stat(path)
    if not stat then
      callback({
        content = { "Path not found: " .. (args.path or "root") },
        kind = "failed",
      })
      return
    end

    if stat.type == "directory" then
      -- List directory
      local files = vim.fn.glob(vim.fs.joinpath(path, "*"), true, true)
      local output =
        { "Directory listing for " .. (args.path or "/memories") .. ":", "" }
      for _, file in ipairs(files) do
        local name = vim.fs.basename(file)
        local fstat = vim.loop.fs_stat(file)
        local type_suffix = fstat and fstat.type == "directory" and "/" or ""
        table.insert(output, "- " .. name .. type_suffix)
      end
      callback({
        content = output,
        display_content = { "📂 Viewed directory " .. (args.path or "/memories") },
      })
    else
      -- Read file
      local lines = vim.fn.readfile(path)
      local start_line = 1
      local end_line = #lines

      if args.view_range and #args.view_range == 2 then
        start_line = math.max(1, args.view_range[1])
        end_line = math.min(#lines, args.view_range[2])
      end

      local content = {}
      for i = start_line, end_line do
        table.insert(content, lines[i])
      end

      local display_info = string.format("📖 Viewed %s", args.path)
      if args.view_range then
        display_info = display_info
          .. string.format(" (lines %d-%d)", start_line, end_line)
      end

      callback({ content = content, display_content = { display_info } })
    end
  elseif args.command == "create" then
    if not args.file_text then
      callback({ content = { "Error: file_text required for create" }, kind = "failed" })
      return
    end

    -- Ensure parent dir exists
    local parent = vim.fs.dirname(path)
    if vim.fn.isdirectory(parent) == 0 then
      vim.fn.mkdir(parent, "p")
    end

    local lines = vim.split(args.file_text, "\n")
    vim.fn.writefile(lines, path)
    callback({
      content = { "Successfully created " .. args.path },
      display_content = { "💾 Created memory " .. args.path },
    })
  elseif args.command == "str_replace" then
    if not args.old_str or not args.new_str then
      callback({ content = { "Error: old_str and new_str required" }, kind = "failed" })
      return
    end
    if vim.fn.filereadable(path) == 0 then
      callback({ content = { "File not found: " .. args.path }, kind = "failed" })
      return
    end

    local lines = vim.fn.readfile(path)
    -- Use matcher to find the span
    local result = matcher.find_best_match(args.old_str, lines)

    if not result or #result.matches == 0 then
      callback({ content = { "Could not find old_str in file" }, kind = "failed" })
      return
    end

    local match = result.matches[1]
    local span = match.span
    local col_span = match.col_span

    -- Prepare new lines
    local new_lines = vim.split(args.new_str, "\n")

    -- If it's an inline match (col_span present)
    if col_span then
      local line_idx = span[1]
      local line = lines[line_idx]
      local prefix = string.sub(line, 1, col_span[1] - 1)
      local suffix = string.sub(line, col_span[2] + 1)

      if #new_lines == 1 then
        lines[line_idx] = prefix .. new_lines[1] .. suffix
      else
        -- Multi-line replacement for inline match
        lines[line_idx] = prefix .. new_lines[1]
        for i = 2, #new_lines - 1 do
          table.insert(lines, line_idx + i - 1, new_lines[i])
        end
        table.insert(lines, line_idx + #new_lines - 1, new_lines[#new_lines] .. suffix)
      end
    else
      -- Remove old lines
      for _ = span[1], span[2] do
        table.remove(lines, span[1])
      end
      -- Insert new lines
      for i, nl in ipairs(new_lines) do
        table.insert(lines, span[1] + i - 1, nl)
      end
    end

    vim.fn.writefile(lines, path)
    callback({
      content = { "Successfully replaced text in " .. args.path },
      display_content = { "✏️ Edited memory " .. args.path },
    })
  elseif args.command == "insert" then
    if not args.insert_line or not args.insert_text then
      callback({
        content = { "Error: insert_line and insert_text required" },
        kind = "failed",
      })
      return
    end
    if vim.fn.filereadable(path) == 0 then
      callback({ content = { "File not found: " .. args.path }, kind = "failed" })
      return
    end

    local lines = vim.fn.readfile(path)
    local insert_lines = vim.split(args.insert_text, "\n")
    local idx = math.max(1, math.min(#lines + 1, args.insert_line))

    for i, line in ipairs(insert_lines) do
      table.insert(lines, idx + i - 1, line)
    end

    vim.fn.writefile(lines, path)
    callback({
      content = { "Successfully inserted text at line " .. idx },
      display_content = { "✏️ Inserted into memory " .. args.path },
    })
  elseif args.command == "delete" then
    if vim.fn.delete(path, "rf") == 0 then
      callback({
        content = { "Successfully deleted " .. args.path },
        display_content = { "🗑️ Deleted memory " .. args.path },
      })
    else
      callback({ content = { "Failed to delete " .. args.path }, kind = "failed" })
    end
  elseif args.command == "rename" then
    local old = resolve_path(args.old_path)
    local new = resolve_path(args.new_path)

    if args.old_path and not old then
      callback({
        content = { "Error: Invalid old_path" },
        kind = "failed",
      })
      return
    end

    if args.new_path and not new then
      callback({
        content = { "Error: Invalid new_path" },
        kind = "failed",
      })
      return
    end

    if not old or not new then
      callback({
        content = { "Error: old_path and new_path required" },
        kind = "failed",
      })
      return
    end

    -- Ensure parent of new exists
    local parent = vim.fs.dirname(new)
    if vim.fn.isdirectory(parent) == 0 then
      vim.fn.mkdir(parent, "p")
    end

    if vim.fn.rename(old, new) == 0 then
      callback({
        content = {
          "Successfully renamed " .. args.old_path .. " to " .. args.new_path,
        },
      })
    else
      callback({ content = { "Failed to rename" }, kind = "failed" })
    end
  else
    callback({
      content = { "Unknown command: " .. (args.command or "nil") },
      kind = "failed",
    })
  end
end)
