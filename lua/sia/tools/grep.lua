local tool_utils = require("sia.tools.utils")
local MAX_LINE_LENGTH = 200
local MAX_MATCHES = 100

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
      "🔍 No files found matching `%s`",
      args.pattern
    ) .. format_no_match_context(args)

    callback({
      content = { "No files with matches found." },
      display_content = { no_match_msg },
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
    "🔍 Found %d files matching `%s`",
    #lines,
    args.pattern
  ) .. format_no_match_context(args)

  callback({
    content = output,
    display_content = { display_msg },
  })
end

local function handle_count_mode(lines, args, callback)
  if #lines == 0 then
    local no_match_msg = string.format("🔍 No matches found for `%s`", args.pattern)
      .. format_no_match_context(args)

    callback({
      content = { "No matches found." },
      display_content = { no_match_msg },
    })
    return
  end

  local is_single_file = false
  if args.path then
    local stat = vim.loop.fs_stat(args.path)
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
    "🔍 Found %d matches in %d files for `%s`",
    total_count,
    #file_counts,
    args.pattern
  ) .. format_no_match_context(args)

  callback({
    content = output,
    display_content = { display_msg },
  })
end

local function handle_content_mode(lines, args, callback)
  local matches = {}
  local file_mtimes = {}

  local is_single_file = false
  if args.path then
    local stat = vim.loop.fs_stat(args.path)
    is_single_file = stat ~= nil and stat.type == "file"
  end

  for _, line in ipairs(lines) do
    local file, lnum, col, rest

    if is_single_file then
      lnum, col, rest = line:match("^(%d+):(%d+):(.*)$")
      if lnum and col then
        file = args.path
      end
    else
      file, lnum, col, rest = line:match("^([^:]+):(%d+):(%d+):(.*)$")
    end

    if file and lnum and col then
      local truncated_line = line
      if #line > MAX_LINE_LENGTH then
        local prefix = string.format("%s:%s:%s:", file, lnum, col)
        local available_length = MAX_LINE_LENGTH - #prefix - 10
        local truncated_rest = rest:sub(1, available_length)
        truncated_line = prefix .. truncated_rest .. "...[TRUNCATED]"
      end

      table.insert(matches, {
        file = file,
        lnum = tonumber(lnum),
        col = tonumber(col),
        text = truncated_line,
      })
      if not file_mtimes[file] then
        local stat = vim.loop.fs_stat(file)
        file_mtimes[file] = stat and stat.mtime and stat.mtime.sec or 0
      end
    end
  end

  if #matches == 0 then
    local no_match_msg = string.format("🔍 No matches found for `%s`", args.pattern)
      .. format_no_match_context(args)

    callback({
      content = { "No matches found." },
      display_content = { no_match_msg },
    })
    return
  end

  table.sort(matches, function(a, b)
    return (file_mtimes[a.file] or 0) > (file_mtimes[b.file] or 0)
  end)

  local header = "The following search results were returned"
  if #matches > MAX_MATCHES then
    header = header
      .. string.format(
        "\n\nWARNING: Search returned %d matches (showing %d most recent by file mtime). Results may be incomplete.",
        #matches,
        MAX_MATCHES
      )
    header = header .. "\nConsider:"
    header = header .. "\n- Using a more specific search pattern"
    header = header .. "\n- Adding a glob parameter to limit file types"
  else
    header = header .. string.format(" (%d matches found)", #matches)
  end

  local output = {}
  for _, line in ipairs(vim.split(header, "\n", { trimempty = false })) do
    table.insert(output, line)
  end

  for i = 1, math.min(#matches, MAX_MATCHES) do
    table.insert(output, matches[i].text)
  end

  local display_msg = string.format("🔍 Found matches for `%s`", args.pattern)
    .. format_no_match_context(args)

  callback({
    content = output,
    display_content = { display_msg },
  })
end

return tool_utils.new_tool({
  name = "grep",
  read_only = true,
  system_prompt = [[A powerful search tool built on ripgrep

Usage:
- ALWAYS use grep for search tasks. NEVER invoke `grep` or `rg` as a bash command. The grep tool has been optimized for correct permissions and access.
- Supports full regex syntax (e.g., "log.*Error", "function\\s+\\w+")
- Filter files with glob parameter (e.g., "*.js", "**/*.tsx") or type parameter (e.g., "js", "py", "rust")
- Output modes: "content" (default) shows matching lines with context, "files_with_matches" shows only file paths, "count" shows match counts per file
- Use the task tool for open-ended searches requiring multiple rounds
- Pattern syntax: Uses ripgrep (not grep) - literal braces need escaping (use `interface\\{\\}` to find `interface{}` in Go code)
- Multiline matching: By default patterns match within single lines only. For cross-line patterns like `struct \\{[\\s\\S]*?field`, use `multiline: true`]],
  message = function(args)
    return string.format("Searching through files for %s...", args.pattern)
  end,
  description = "Grep for a pattern in files using rg",
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
  auto_apply = function(args, conversation)
    return conversation.auto_confirm_tools["grep"]
  end,
  required = { "pattern" },
}, function(args, _, callback, opts)
  local output_mode = args.output_mode or "content"
  local command = { "rg", "--no-heading", "--no-follow", "--color=never" }

  if output_mode == "files_with_matches" then
    table.insert(command, "-l")
  elseif output_mode == "count" then
    table.insert(command, "-c")
  else
    table.insert(command, "--column")
  end

  if args.multiline then
    table.insert(command, "--multiline")
  end

  if args.glob then
    table.insert(command, "--glob")
    table.insert(command, args.glob)
  end

  if args.pattern == nil then
    callback({ content = { "No pattern was given" } })
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

      local root = require("sia.utils").detect_project_root(vim.fn.getcwd())
      vim.system(command, {
        text = true,
        stderr = false,
        timeout = 5000,
        cwd = root,
      }, function(obj)
        local lines = vim.split(obj.stdout, "\n", { trimempty = true })

        if output_mode == "files_with_matches" then
          handle_files_with_matches_mode(lines, args, callback)
        elseif output_mode == "count" then
          handle_count_mode(lines, args, callback)
        else
          handle_content_mode(lines, args, callback)
        end
      end)
    end,
  })
end)
