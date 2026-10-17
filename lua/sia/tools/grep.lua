local tool_utils = require("sia.tools.utils")

local function format_no_match_context(args)
  local context = ""
  if args.glob and args.path then
    context = string.format(" in files matching `%s` within `%s`", args.glob, args.path)
  elseif args.glob then
    context = string.format(" in files matching `%s`", args.glob)
  elseif args.path then
    context = string.format(" in `%s`", args.path)
  end
  return context
end

local function handle_files_with_matches_mode(lines, args, callback)
  if #lines == 0 then
    local no_match_msg = string.format(
      "No files found matching `%s`",
      args.pattern
    ) .. format_no_match_context(args)

    callback({
      content = "No files with matches found.",
      summary = no_match_msg,
    })
    return
  end

  local header =
    string.format("Files containing matches for `%s` (%d files):", args.pattern, #lines)
  local output = { header }
  for _, file in ipairs(lines) do
    table.insert(output, file)
  end

  local display_msg = string.format(
    "Found %d files matching `%s`",
    #lines,
    args.pattern
  ) .. format_no_match_context(args)

  callback({
    content = table.concat(output, "\n"),
    summary = display_msg,
    preview = { text = table.concat(lines, "\n"), ft = "text" },
  })
end

local function handle_count_mode(lines, args, callback, conversation)
  if #lines == 0 then
    local no_match_msg = string.format(
      "No matches found for `%s`",
      args.pattern
    ) .. format_no_match_context(args)

    callback({
      content = "No matches found.",
      summary = no_match_msg,
    })
    return
  end

  local is_single_file = false
  if args.path then
    local stat = vim.loop.fs_stat(tool_utils.resolve_workspace_path(args.path, conversation.workspace))
    is_single_file = stat ~= nil and stat.type == "file"
  end

  local total_count = 0
  local file_counts = {}
  for _, line in ipairs(lines) do
    local file, count

    if is_single_file then
      count = line:match("^(%d+)$")
      if count then
        file = args.path
      end
    else
      file, count = line:match("^([^:]+):(%d+)$")
    end

    if file and count then
      local cnt = tonumber(count)
      table.insert(file_counts, { file = file, count = cnt })
      total_count = total_count + cnt
    end
  end

  table.sort(file_counts, function(a, b)
    return a.count > b.count
  end)

  local header = string.format(
    "Match counts for `%s` (total: %d matches in %d files):",
    args.pattern,
    total_count,
    #file_counts
  )
  local output = { header }
  for _, item in ipairs(file_counts) do
    table.insert(output, string.format("%s: %d", item.file, item.count))
  end

  local display_msg = string.format(
    "Found %d matches in %d files for `%s`",
    total_count,
    #file_counts,
    args.pattern
  ) .. format_no_match_context(args)

  callback({
    content = table.concat(output, "\n"),
    summary = display_msg,
    preview = { text = table.concat(vim.list_slice(output, 2), "\n"), ft = "text" },
  })
end

return tool_utils.new_tool({
  definition = {
    type = "function",
    name = "grep",
    description = "Search files on disk using rg. Content results include buffer-based hashline tags and surrounding context (1 line before, 3 after), usable directly by edit without a separate view. Unsaved-only matches are not searched.",
    parameters = {
      glob = { type = "string", description = "Glob pattern for files to search" },
      pattern = { type = "string", description = "Search pattern" },
      path = {
        type = "string",
        description = "Directory or file path to search within (e.g., `lua/sia`, `lua/sia/config.lua`, `.`). If not provided, searches from current directory.",
      },
      output_mode = {
        type = "string",
        description = 'Output mode: "content" (default, shows matching lines), "files_with_matches" (only file paths), "count" (match counts per file)',
        enum = { "content", "files_with_matches", "count" },
      },
      multiline = {
        type = "boolean",
        description = "Enable multiline matching for patterns that span multiple lines (e.g., matching code blocks). Default is false.",
      },
    },
    required = { "pattern" },
  },
  read_only = true,
  instructions = [[A powerful search tool built on ripgrep

Usage:
- ALWAYS use grep for search tasks. NEVER invoke `grep` or `rg` as a bash command. The grep tool has been optimized for correct permissions and access.
- Supports full regex syntax (e.g., "log.*Error", "function\\s+\\w+")
- Filter files with glob parameter (e.g., "*.js", "**/*.tsx") or type parameter (e.g., "js", "py", "rust")
- Output modes: "content" (default) shows matching lines with context, "files_with_matches" shows only file paths, "count" shows match counts per file
- Use the task tool for open-ended searches requiring multiple rounds
- Pattern syntax: Uses ripgrep (not grep) - literal braces need escaping (use `interface\\{\\}` to find `interface{}` in Go code)
- Multiline matching: By default patterns match within single lines only. For cross-line patterns like `struct \\{[\\s\\S]*?field`, use `multiline: true`]],
  summary = function(args)
    return string.format("Searching for %s...", args.pattern)
  end,
  is_approved = function(args, conversation)
    if args.path and require("sia.utils").dirs.is_safe(args.path) then
      return true
    end
    return conversation.approved_tools["grep"]
  end,
}, function(args, conversation, callback, opts)
  local result_callback = callback
  callback = function(result)
    if result.summary then
      result.summary = string.format("Searched `%s` in `%s`", args.pattern, args.path or ".")
    end
    result_callback(result)
  end
  local output_mode = args.output_mode or "content"
  local command = { "rg", "--no-heading", "--no-follow", "--color=never" }

  if output_mode == "files_with_matches" then
    table.insert(command, "-l")
  elseif output_mode == "count" then
    table.insert(command, "-c")
  else
    table.insert(command, "--json")
  end

  if args.multiline then
    table.insert(command, "--multiline")
  end

  if args.glob then
    table.insert(command, "--glob")
    table.insert(command, args.glob)
  end

  if args.pattern == nil then
    callback({ content = "No pattern was given" })
    return
  end

  local prompt = string.format("Search for `%s` in all files", args.pattern)
  if args.glob and args.path then
    prompt = string.format(
      "Search for `%s` in files matching `%s` within `%s`",
      args.pattern,
      args.glob,
      args.path
    )
  elseif args.glob then
    prompt =
      string.format("Search for `%s` in files matching `%s`", args.pattern, args.glob)
  elseif args.path then
    prompt = string.format("Search for `%s` in `%s`", args.pattern, args.path)
  end

  opts.user_input(prompt, {
    on_accept = function()
      table.insert(command, "--")
      table.insert(command, args.pattern)
      if args.path then
        table.insert(command, args.path)
      end

      vim.system(command, {
        text = true,
        timeout = 5000,
        cwd = conversation.workspace,
      }, vim.schedule_wrap(function(obj)
        if obj.code ~= 0 and obj.code ~= 1 then
          callback({ content = "Search failed: " .. (obj.stderr or "rg exited with code " .. obj.code), ephemeral = true })
          return
        end
        local lines = vim.split(obj.stdout or "", "\n", { trimempty = true })

        if output_mode == "files_with_matches" then
          handle_files_with_matches_mode(lines, args, callback)
        elseif output_mode == "count" then
          handle_count_mode(lines, args, callback, conversation)
        else
          callback(require("sia.tools.grep_context").build(lines, args, conversation))
        end
      end))
    end,
  })
end)
