local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local MAX_LINE_LENGTH = 200
local MAX_MATCHES = 100

return tool_utils.new_tool({
  name = "grep",
  read_only = true,
  system_prompt = [[- Fast content search
- Searches files using regluar expressions as supported by rg
- Supports glob patterns to specify files
- Optionally specify a path to search within a specific directory or file
- The root of the search is the current working directory (or specified path)
- Do not use search to get the content of a file, use tools or ask the user to
  add the information.
- When you are doing an open ended search that may require multiple rounds of
  globbing and grepping, use the dispatch_agent tool instead]],
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
  },
  auto_apply = function(args, conversation)
    if utils.is_memory(args.path) then
      return 1
    end
    return conversation.auto_confirm_tools["grep"]
  end,
  required = { "pattern" },
}, function(args, _, callback, opts)
  local command = { "rg", "--column", "--no-heading", "--no-follow", "--color=never" }
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

      vim.system(command, {
        text = true,
        stderr = false,
        timeout = 5000,
      }, function(obj)
        local lines = vim.split(obj.stdout, "\n", { trimempty = true })
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
        local is_memory = args.path and utils.is_memory(args.path)
        if #matches == 0 and not is_memory then
          local no_match_msg =
            string.format("🔍 No matches found for `%s`", args.pattern)
          if args.glob and args.path then
            no_match_msg = no_match_msg
              .. string.format(
                " in files matching `%s` within `%s`",
                args.glob,
                args.path
              )
          elseif args.glob then
            no_match_msg = no_match_msg
              .. string.format(" in files matching `%s`", args.glob)
          elseif args.path then
            no_match_msg = no_match_msg .. string.format(" in `%s`", args.path)
          end

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
        if args.glob and args.path then
          display_msg = display_msg
            .. string.format(" in `%s` within `%s`", args.glob, args.path)
        elseif args.glob then
          display_msg = display_msg .. string.format(" in `%s`", args.glob)
        elseif args.path then
          display_msg = display_msg .. string.format(" in `%s`", args.path)
        end

        callback({
          content = output,
          display_content = not is_memory and { display_msg } or nil,
        })
      end)
    end,
  })
end)
