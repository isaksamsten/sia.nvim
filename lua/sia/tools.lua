local M = {}

---@class SiaNewToolOpts
---@field name string
---@field description string
---@field auto_apply (fun(args: table):integer?)?
---@field message string|(fun(args:table):string)?
---@field system_prompt string?
---@field required string[]
---@field parameters table
---@field confirm (string|fun(args:table):string)?
---@field select { prompt: (string|fun(args:table):string)?, choices: string[]}?

--- @type table<string, boolean?>
local auto_confirm = {}

---@param buf integer
---@param original_content string[]
---@param target_file string
local function show_diff_preview(buf, original_content)
  local timestamp = os.date("%H:%M:%S")
  vim.cmd("tabnew")
  local left_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, original_content)
  vim.api.nvim_buf_set_name(left_buf, string.format("%s [ORIGINAL @ %s]", vim.api.nvim_buf_get_name(buf), timestamp))
  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].buflisted = false
  vim.bo[left_buf].swapfile = false
  vim.bo[left_buf].ft = vim.bo[buf].ft

  vim.cmd("vsplit")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, buf)
  vim.api.nvim_set_current_win(right_win)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(vim.fn.win_getid(vim.fn.winnr("#")))
  vim.cmd("diffthis")
  vim.bo[left_buf].modifiable = false
  vim.api.nvim_set_current_win(right_win)
end

---@param opts SiaNewToolOpts
---@param execute fun(args: table, conversation: sia.Conversation, callback: (fun(result: sia.ToolResult):nil), choice: integer?):nil
---@return sia.config.Tool
M.new_tool = function(opts, execute)
  local auto_apply = function(args)
    --- Ensure that we auto apply incorrect tool calls
    if vim.iter(opts.required):any(function(required)
      return args[required] == nil
    end) then
      return 0
    end

    if auto_confirm[opts.name] then
      return 1
    else
      return (opts.auto_apply and opts.auto_apply(args)) or nil
    end
  end

  return {
    name = opts.name,
    message = opts.message,
    parameters = opts.parameters,
    system_prompt = opts.system_prompt,
    is_interactive = function(conversation, args)
      if conversation.ignore_tool_confirm then
        return false
      end
      if opts.confirm ~= nil or opts.select ~= nil then
        return auto_apply(args) == nil
      end
      return false
    end,
    description = opts.description,
    required = opts.required,
    execute = function(args, conversation, callback)
      if conversation.ignore_tool_confirm then
        opts.confirm = nil
      end
      if opts.confirm ~= nil then
        if auto_apply(args) then
          execute(args, conversation, callback)
          return
        end

        local text
        if type(opts.confirm) == "function" then
          text = opts.confirm(args)
        else
          text = opts.confirm
        end
        vim.ui.input(
          { prompt = string.format("%s\nProceed and send to AI? [Y/n/a] ([Y]es, [n]o or Esc, [a]lways): ", text) },
          function(resp)
            if resp == nil then
              callback({ content = string.format("User cancelled %s operation.", opts.name), cancel = true })
              return
            end

            local response = resp:lower()
            if response == "a" or response == "always" then
              auto_confirm[opts.name] = true
              execute(args, conversation, callback)
            elseif response == "n" or response == "no" then
              callback({ content = string.format("User declined to execute %s.", opts.name) })
            else
              execute(args, conversation, callback)
            end
          end
        )
      elseif opts.select then
        local auto_applied_choice = auto_apply(args)
        if auto_applied_choice then
          execute(args, conversation, callback, auto_applied_choice)
        else
          local prompt
          if type(opts.select.prompt) == "function" then
            prompt = opts.select.prompt(args)
          else
            prompt = opts.select.prompt
          end
          vim.ui.select(
            opts.select.choices,
            { prompt = string.format("%s\nChoose an action (Esc to cancel):", prompt) },
            function(_, idx)
              if idx == nil or idx < 1 or idx > #opts.select.choices then
                callback({ content = string.format("User cancelled %s operation.", opts.name) })
                return
              end
              execute(args, conversation, callback, idx)
            end
          )
        end
      else
        execute(args, conversation, callback)
      end
    end,
  }
end
local KINDS = {
  [1] = "File",
  [2] = "Module",
  [3] = "Namespace",
  [4] = "Package",
  [5] = "Class",
  [6] = "Method",
  [7] = "Property",
  [8] = "Field",
  [9] = "Constructor",
  [10] = "Enum",
  [11] = "Interface",
  [12] = "Function",
  [13] = "Variable",
  [14] = "Constant",
  [15] = "String",
  [16] = "Number",
  [17] = "Boolean",
  [18] = "Array",
  [19] = "Object",
  [20] = "Key",
  [21] = "Null",
  [22] = "EnumMember",
  [23] = "Struct",
  [24] = "Event",
  [25] = "Operator",
  [26] = "TypeParameter",
}

M.find_lsp_symbol = M.new_tool({
  name = "find_lsp_symbol",
  message = function(args)
    if #args.queries == 1 then
      return string.format("Searching for LSP symbols matching '%s'...", args.queries[1])
    else
      return string.format("Searching for LSP symbols matching %d queries...", #args.queries)
    end
  end,
  system_prompt = [[Search for LSP symbols in the workspace and make them available for further exploration.

This tool is extremely useful for:
- Finding functions, classes, methods, and variables by name across the entire project
- Discovering code structure and understanding how components are organized
- Locating specific symbols when you need to understand their implementation
- Building context for code analysis tasks
- Finding entry points and key components in unfamiliar codebases

SEARCH STRATEGY:
- Use partial names or patterns - LSP will find fuzzy matches
- Search for multiple related terms in one call for efficiency
- Combine with show_locations to create navigable lists of results
- Follow up with read tool to examine specific symbol implementations

SYMBOL TYPES FOUND:
- Functions, methods, and constructors
- Classes, interfaces, and types
- Variables, constants, and properties
- Modules, namespaces, and packages
- Enums, structs, and other language-specific constructs

INTEGRATION WITH OTHER TOOLS:
- Results are stored for use with symbol_docs tool
- Use show_locations to create quickfix lists from results
- Follow up with read tool to examine symbol definitions
- Combine with grep for broader context searches]],
  description = "Search for LSP symbols across the workspace and prepare them for further exploration",
  parameters = {
    queries = {
      type = "array",
      items = { type = "string" },
      description = "Search queries for symbol names (supports partial/fuzzy matching)",
    },
    kind_filter = {
      type = "array",
      items = { type = "string" },
      description = "Optional filter by symbol types: Function, Class, Method, Variable, Constant, etc.",
    },
    project_only = {
      type = "boolean",
      description = "Only show symbols from the current project root (default: true)",
    },
    max_results = {
      type = "integer",
      description = "Maximum number of results to return per query (default: 50)",
    },
  },
  required = { "queries" },
  confirm = function(args)
    if #args.queries == 1 then
      return string.format("Search workspace for symbols matching '%s'", args.queries[1])
    else
      return string.format("Search workspace for symbols matching %s", table.concat(args.queries, "', '"))
    end
  end,
}, function(args, conversation, callback)
  if not args.queries or #args.queries == 0 then
    callback({ content = { "Error: No search queries provided" } })
    return
  end

  local clients = vim.lsp.get_clients({ method = "workspace/symbol" })
  if vim.tbl_isempty(clients) then
    callback({
      content = {
        "Error: No LSP clients with workspace symbol support found",
        "Make sure an LSP server is running and supports workspace/symbol requests",
      },
    })
    return
  end

  -- Configuration
  local project_only = args.project_only ~= false -- default to true
  local max_results = args.max_results or 50
  local kind_filter = args.kind_filter or {}
  local kind_filter_set = {}
  for _, kind in ipairs(kind_filter) do
    kind_filter_set[kind:lower()] = true
  end

  local all_found = {}
  local done = {}
  local total_requests = 0

  -- Initialize conversation storage
  conversation.lsp_symbols = conversation.lsp_symbols or {}

  for i, client in ipairs(clients) do
    for j, query in ipairs(args.queries) do
      total_requests = total_requests + 1
      local request_id = string.format("%d_%d", i, j)
      done[request_id] = false

      local params = { query = query }

      client:request("workspace/symbol", params, function(err, symbols)
        if err then
          done[request_id] = true
          return
        end

        if symbols then
          for _, symbol in ipairs(symbols) do
            local uri = vim.uri_to_fname(symbol.location.uri)
            local in_root = vim.startswith(uri, client.root_dir or vim.fn.getcwd())

            -- Apply filters
            if project_only and not in_root then
              goto continue
            end

            local kind_name = KINDS[symbol.kind] or "Unknown"
            if #kind_filter > 0 and not kind_filter_set[kind_name:lower()] then
              goto continue
            end

            -- Store symbol for later use
            local symbol_key = string.format("%s_%s_%d", symbol.name, kind_name, symbol.location.range.start.line)
            conversation.lsp_symbols[symbol_key] = symbol

            table.insert(all_found, {
              symbol = symbol,
              in_root = in_root,
              query = query,
              client_name = client.name,
              key = symbol_key,
            })

            ::continue::
          end
        end

        done[request_id] = true
      end)
    end
  end

  -- Wait for all requests to complete
  local success = vim.wait(3000, function()
    return vim.iter(done):all(function(v)
      return v
    end)
  end, 50)

  if not success then
    callback({
      content = {
        "Warning: Some LSP requests timed out",
        "Results may be incomplete",
      },
    })
  end

  if #all_found == 0 then
    callback({
      content = {
        string.format("No symbols found matching: %s", table.concat(args.queries, ", ")),
        "",
        "Try:",
        "- Using partial names or different search terms",
        "- Removing kind_filter if specified",
        "- Setting project_only to false to search external dependencies",
      },
    })
    return
  end

  -- Sort and limit results
  table.sort(all_found, function(a, b)
    -- Prioritize project symbols over external
    if a.in_root ~= b.in_root then
      return a.in_root
    end
    -- Then by symbol kind (functions/classes first)
    local a_kind, b_kind = a.symbol.kind, b.symbol.kind
    if a_kind ~= b_kind then
      local priority = { [12] = 1, [5] = 2, [6] = 3, [9] = 4 } -- Function, Class, Method, Constructor
      return (priority[a_kind] or 99) < (priority[b_kind] or 99)
    end
    -- Finally by name
    return a.symbol.name < b.symbol.name
  end)

  -- Limit results per query
  local results_by_query = {}
  for _, item in ipairs(all_found) do
    results_by_query[item.query] = results_by_query[item.query] or {}
    if #results_by_query[item.query] < max_results then
      table.insert(results_by_query[item.query], item)
    end
  end

  -- Build response
  local content = {}
  local total_symbols = 0

  for _, query in ipairs(args.queries) do
    local query_results = results_by_query[query] or {}
    if #query_results > 0 then
      table.insert(content, string.format("=== Symbols matching '%s' ===", query))

      for _, item in ipairs(query_results) do
        local symbol = item.symbol
        local rel_path = vim.fn.fnamemodify(vim.uri_to_fname(symbol.location.uri), ":.")
        local kind = KINDS[symbol.kind] or "Unknown"
        local start_line = symbol.location.range.start.line + 1
        local end_line = symbol.location.range["end"].line + 1

        local location_info
        if start_line == end_line then
          location_info = item.in_root and string.format("%s:%d", rel_path, start_line)
            or string.format("[external] %s:%d", rel_path, start_line)
        else
          location_info = item.in_root and string.format("%s:%d-%d", rel_path, start_line, end_line)
            or string.format("[external] %s:%d-%d", rel_path, start_line, end_line)
        end

        local container = symbol.containerName and string.format(" (in %s)", symbol.containerName) or ""
        table.insert(
          content,
          string.format("  %s: %s%s → %s [key: %s]", kind, symbol.name, container, location_info, item.key)
        )
        total_symbols = total_symbols + 1
      end
      table.insert(content, "")
    else
      table.insert(content, string.format("No symbols found for '%s'", query))
      table.insert(content, "")
    end
  end

  -- Add usage instructions
  table.insert(content, string.format("Found %d total symbols across %d queries", total_symbols, #args.queries))
  table.insert(content, "")
  table.insert(content, "Next steps:")
  table.insert(content, "- Use get_lsp_symbol_docs tool with the [key] to get documentation")
  table.insert(content, "- Use read tool with file:line to examine implementations")
  table.insert(content, "- Use show_locations to create a navigable quickfix list")

  callback({ content = content })
end)

M.get_lsp_symbol_docs = M.new_tool({
  name = "get_lsp_symbol_docs",
  message = function(args)
    return string.format("Getting documentation for symbol '%s'...", args.symbol)
  end,
  system_prompt = [[Get detailed documentation for LSP symbols that were previously found using find_lsp_symbol.

This tool retrieves hover information and documentation for specific symbols in your codebase. It works by:

1. Looking up the symbol from previously stored find_lsp_symbol results
2. Making LSP hover requests to get documentation
3. Converting the response to readable markdown format

USAGE FLOW:
1. First use find_lsp_symbol to search for symbols of interest
2. Note the [key] values shown in the search results
3. Use this tool with the key to get detailed documentation

DOCUMENTATION INCLUDES:
- Function/method signatures and parameter information
- Type definitions and return types
- Docstrings, comments, and inline documentation
- Usage examples (when available from LSP)
- Related type information

The symbol parameter should be the exact key shown in find_lsp_symbol results
(e.g., "MyClass_Class_42").

This tool is essential for understanding code structure and API documentation
without leaving the editor.]],
  description = "Get detailed documentation and hover information for LSP symbols found via find_lsp_symbol",
  parameters = {
    symbol = {
      type = "string",
      description = "The symbol key from find_lsp_symbol results to get documentation for",
    },
  },
  required = { "symbol" },
}, function(args, conversation, callback)
  if not args.symbol then
    callback({ content = { "Error: No symbol provided" } })
    return
  end

  --- @diagnostic disable-next-line undefined-field
  if conversation.lsp_symbols == nil then
    callback({ content = { "Error: No symbols have been added to the conversation yet. Use find_lsp_symbol first." } })
    return
  end

  --- @diagnostic disable-next-line undefined-field
  local symbol = conversation.lsp_symbols[args.symbol]

  if symbol == nil then
    callback({
      content = {
        string.format("Error: The symbol '%s' was not found in the conversation.", args.symbol),
        "Available symbols:",
        table.concat(vim.tbl_keys(conversation.lsp_symbols), ", "),
      },
    })
    return
  end

  local clients = vim.lsp.get_clients({ method = "textDocument/hover" })
  if vim.tbl_isempty(clients) then
    callback({ content = { "Error: No LSP clients with hover support found" } })
    return
  end

  local done = {}
  local found = {}

  local params = {
    position = {
      character = symbol.location.range.start.character,
      line = symbol.location.range.start.line,
    },
    textDocument = {
      uri = symbol.location.uri,
    },
  }

  for i, client in ipairs(clients) do
    done[i] = false

    client:request("textDocument/hover", params, function(err, resp)
      if err or resp == nil then
        done[i] = true
        return
      end
      table.insert(found, { client = client.name, response = resp })
      done[i] = true
    end)
  end

  local success = vim.wait(3000, function()
    return vim.iter(done):all(function(v)
      return v
    end)
  end, 50)

  if not success then
    callback({ content = { "Warning: LSP hover request timed out for symbol: " .. args.symbol } })
    return
  end

  if #found == 0 then
    callback({
      content = {
        string.format("No documentation found for symbol: %s", args.symbol),
        "",
        "This could mean:",
        "- The symbol has no associated documentation",
        "- The LSP server doesn't support hover for this symbol type",
        "- The symbol location is no longer valid",
      },
    })
    return
  end

  local content = { string.format("=== Documentation for '%s' ===", symbol.name), "" }

  for _, result in ipairs(found) do
    if result.response.contents then
      local doc_lines = vim.lsp.util.convert_input_to_markdown_lines(result.response.contents)
      if #doc_lines > 0 then
        table.insert(content, string.format("From %s LSP:", result.client))
        vim.list_extend(content, doc_lines)
        table.insert(content, "")
      end
    end
  end

  -- Add symbol location info
  local rel_path = vim.fn.fnamemodify(vim.uri_to_fname(symbol.location.uri), ":.")
  local line = symbol.location.range.start.line + 1
  table.insert(content, string.format("Symbol location: %s:%d", rel_path, line))

  callback({ content = content })
end)

M.read = M.new_tool({
  name = "read",
  message = "Reading file contents...",
  system_prompt = [[Reads a file from the local filesystem.

You can optionally specify a start line and an end line (especially handy for long
files), but it's recommended to read the whole file by not providing these
parameters. ]],
  description = [[Reads a file from the local filesystem.]],
  parameters = {
    path = { type = "string", description = "The file path" },
    start_line = { type = "integer", description = "The start line number. Ignore if reading the complete file." },
    end_line = {
      type = "integer",
      description = "The end line number. Ignore if reading the complete file. If missing, read until end of file.",
    },
  },
  required = { "path" },
  confirm = function(args)
    if args.start_line then
      if args.end_line then
        return string.format(
          "Add lines %s-%s from %s to the conversation",
          tostring(args.start_line),
          tostring(args.end_line),
          args.path
        )
      else
        return string.format("Add lines %s-until end from %s to the conversation", tostring(args.start_line), args.path)
      end
    end
    return string.format("Add %s to the conversation", args.path)
  end,
  --- @param conversation sia.Conversation
}, function(args, conversation, callback)
  if not args.path then
    callback({ content = { "Error: No file path was provided" } })
    return
  end

  if vim.fn.filereadable(args.path) == 0 then
    callback({ content = { "Error: File cannot be found" } })
    return
  end

  local pos = nil
  if args.start_line then
    if args.end_line then
      pos = { args.start_line, args.end_line }
    else
      pos = { args.start_line, -1 }
    end
  end

  local buf = require("sia.utils").ensure_file_is_loaded(args.path)
  local content

  if pos then
    content = vim.api.nvim_buf_get_lines(buf, pos[1], pos[2], false)
  else
    content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  callback({
    content = content,
    context = { buf = buf, pos = pos, changedtick = vim.b[buf].changedtick },
    kind = "context",
  })
end)

M.grep = M.new_tool({
  name = "grep",
  system_prompt = [[- Fast content search
- Searches files using regluar expressions as supported by rg
- Supports glob patterns to specify files
- The root of the search is always the current working directory
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
  },
  required = { "pattern" },
  confirm = function(args)
    if args.glob then
      return string.format("Search for '%s' in files matching '%s'", args.pattern, args.glob)
    end
    return string.format("Search for '%s' in all files", args.pattern)
  end,
}, function(args, _, callback, choice)
  local command = { "rg", "--column", "--no-heading", "--no-follow", "--color=never" }
  if args.glob then
    table.insert(command, "--glob")
    table.insert(command, args.glob)
  end

  local max_count = 100

  if args.pattern == nil then
    callback({ content = { "No pattern was given" } })
    return
  end

  table.insert(command, "--")
  table.insert(command, args.pattern)

  vim.system(command, {
    text = true,
    stderr = false,
    timeout = 5000,
  }, function(obj)
    local lines = vim.split(obj.stdout, "\n", { trimempty = true })
    local matches = {}
    local file_mtimes = {}

    for _, line in ipairs(lines) do
      local file, lnum, col, rest = line:match("^([^:]+):(%d+):(%d+):(.*)$")
      if file and lnum and col then
        table.insert(matches, { file = file, lnum = tonumber(lnum), col = tonumber(col), text = line })
        if not file_mtimes[file] then
          local stat = vim.loop.fs_stat(file)
          file_mtimes[file] = stat and stat.mtime and stat.mtime.sec or 0
        end
      end
    end
    if #matches == 0 then
      callback({ content = { "No matches found." } })
      return
    end

    table.sort(matches, function(a, b)
      return (file_mtimes[a.file] or 0) > (file_mtimes[b.file] or 0)
    end)

    local header = "The following search results were returned"
    if #matches > max_count then
      header = header
        .. string.format(
          "\n\nWARNING: Search returned %d matches (showing %d most recent by file mtime). Results may be incomplete.",
          #matches,
          max_count
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

    for i = 1, math.min(#matches, max_count) do
      table.insert(output, matches[i].text)
    end
    callback({ content = output })
  end)
end)

M.glob = M.new_tool({
  name = "glob",
  description = "Find files matching a glob pattern in the current project",
  message = "Searching for files...",
  parameters = {
    pattern = {
      type = "string",
      description = "Glob pattern to match files (e.g., '*.lua', '**/*.py', 'src/**'). If not provided, lists all files.",
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
}, function(args, _, callback)
  local cmd = { "fd", "--type", "f", "--print0" }
  local pattern = args.pattern

  if pattern and pattern ~= "" then
    table.insert(cmd, "--glob")
    table.insert(cmd, pattern)
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
      local msg = pattern and ("No files found matching pattern: " .. pattern) or "No files found."
      callback({ content = { msg } })
      return
    end

    -- Get file modification times and sort by mtime (newest first)
    local file_info = {}
    for _, file in ipairs(files) do
      local stat = vim.loop.fs_stat(file)
      if stat then
        table.insert(file_info, {
          path = file,
          mtime = stat.mtime.sec,
        })
      end
    end

    table.sort(file_info, function(a, b)
      return a.mtime > b.mtime
    end)

    -- Limit to 100 files
    local max_files = 100
    local limited_files = {}
    for i = 1, math.min(max_files, #file_info) do
      table.insert(limited_files, file_info[i].path)
    end

    local header = pattern and ("Files matching pattern '" .. pattern .. "' (max " .. max_files .. ", newest first):")
      or ("Files in the current project (max " .. max_files .. ", newest first):")
    table.insert(limited_files, 1, header)

    if #file_info > max_files then
      table.insert(
        limited_files,
        2,
        string.format("Showing %d of %d files (limited to most recent %d)", max_files, #file_info, max_files)
      )
    end

    callback({ content = limited_files })
  end)
end)

--- @type integer?
local edit_file_auto_apply = nil

M.edit_file_agent = M.new_tool({
  name = "edit",
  message = "Making code changes...",
  description = [[Edit an existing file by specifying precise changes.

KEY PRINCIPLES:
- Make ALL edits to a file in a single tool call (use multiple edit blocks if needed)
- Only specify lines you're changing - represent unchanged code with comments

EDIT SYNTAX:
Use "// ... existing code ..." comments to represent unchanged sections:

// ... existing code ...
NEW_OR_MODIFIED_CODE_HERE
// ... existing code ...
ANOTHER_EDIT_HERE
// ... existing code ...

EXAMPLES:

Adding a new function:
```
// ... existing code ...
function newFunction() {
  return "hello";
}
// ... existing code ...
```

Modifying existing code:
```
// ... existing code ...
const updated = "new value";
// ... existing code ...
```

Deleting code (provide context before and after):
```
// ... existing code ...
function keepThis() {}
function alsoKeepThis() {}
// ... existing code ...
```

Multiple changes in one call:
```
// ... existing code ...
FIRST_EDIT
// ... existing code ...
SECOND_EDIT
// ... existing code ...
THIRD_EDIT
// ... existing code ...
```

The apply model will handle multiple distinct edits efficiently in a single operation.]],
  parameters = {
    target_file = {
      type = "string",
      description = "The target file to modify.",
    },
    instructions = {
      type = "string",
      description = [[A single sentence instruction describing what you are
going to do for the sketched edit. This is used to assist the less
intelligent model in applying the edit. Use the first person to describe
what you are going to do. Use it to disambiguate uncertainty in the edit.
      ]],
    },
    code_edit = {
      type = "string",
      description = [[Specify ONLY the precise lines of code that you wish to
edit. NEVER specify or write out unchanged code. Instead, represent all
unchanged code using the comment of the language you're editing in -
example: // ... existing code ...  ]],
    },
  },
  required = { "target_file", "instructions", "code_edit" },
  auto_apply = function(args)
    local file = vim.fs.basename(args.target_file)
    if file == "AGENTS.md" then
      return 1
    end
    return edit_file_auto_apply
  end,
  select = {
    prompt = function(args)
      if args.instructions then
        return string.format("%s\nEdit %s", args.instructions, args.target_file)
      else
        return string.format("Edit %s", args.target_file)
      end
    end,
    choices = {
      "Apply changes immediately",
      "Apply changes immediately and remember this choice",
      "Apply changes and preview them in diff view",
    },
  },
}, function(args, _, callback, choice)
  if not args.target_file then
    callback({ content = { "No target_file was provided" } })
    return
  end

  local buf = require("sia.utils").ensure_file_is_loaded(args.target_file)
  if not buf then
    callback({ content = { "Cannot load " .. args.target_file } })
    return
  end
  local initial_code = require("sia.utils").get_code(1, -1, { buf = buf, show_line_numbers = false })

  local assistant = require("sia.assistant")
  assistant.execute_query({
    model = {
      name = "morph/morph-v3-fast",
      function_calling = false,
      provider = require("sia.provider").openrouter,
    },
    prompt = {
      {
        role = "user",
        content = string.format(
          "<instruction>%s</instruction>\n<code>%s</code>\n<update>%s</update>",
          args.instructions,
          initial_code,
          args.code_edit
        ),
      },
    },
  }, function(result)
    if result then
      local split = vim.split(result, "\n", { plain = true, trimempty = true })
      if choice == 1 or choice == 2 then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, split)
        require("sia").highlight_diff_changes(buf, initial_code, result)

        local file = vim.fs.basename(args.target_file)
        if file == "AGENTS.md" then
          vim.api.nvim_buf_call(buf, function()
            vim.cmd("write")
          end)
        end

        if choice == 2 then
          edit_file_auto_apply = 1
        end
      elseif choice == 3 then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, split)
        show_diff_preview(buf, vim.split(initial_code, "\n", { plain = true, trimempty = true }))
      end
      local diff = vim.split(vim.diff(initial_code, result), "\n", { plain = true, trimempty = true })
      local success_msg = string.format("Successfully edited %s. Here's the resulting diff:", args.target_file)
      table.insert(diff, 1, success_msg)
      callback({ content = diff })
    else
      callback({ content = { string.format("Failed to edit %s", args.target_file) } })
    end
  end)
end)

M.get_diagnostics = M.new_tool({
  name = "get_diagnostics",
  message = "Retrieving diagnostics...",
  description = "Get LSP diagnostics for a specific file",
  parameters = {
    file = { type = "string", description = "The file path to get diagnostics for" },
  },
  required = { "file" },
  confirm = function(args)
    return string.format("Get diagnostics for %s", args.file)
  end,
}, function(args, _, callback, choice)
  if not args.file then
    callback({ content = { "Error: No file path was provided" } })
    return
  end

  if vim.fn.filereadable(args.file) == 0 then
    callback({ content = { "Error: File cannot be found or is not readable" } })
    return
  end
  local buf = require("sia.utils").ensure_file_is_loaded(args.file)
  if not buf then
    callback({ content = { "Error: Cannot load file into buffer" } })
    return
  end

  local diagnostics = vim.diagnostic.get(buf)
  if #diagnostics == 0 then
    callback({
      content = { string.format("No diagnostics found for %s", args.file) },
      context = { buf = buf },
      kind = "diagnostics",
    })
    return
  end

  local content = { string.format("Diagnostics for %s:", args.file), "" }

  local severity_names = {
    [vim.diagnostic.severity.ERROR] = "ERROR",
    [vim.diagnostic.severity.WARN] = "WARNING",
    [vim.diagnostic.severity.INFO] = "INFO",
    [vim.diagnostic.severity.HINT] = "HINT",
  }

  for _, diagnostic in ipairs(diagnostics) do
    local severity = severity_names[diagnostic.severity] or "UNKNOWN"
    local line = diagnostic.lnum + 1 -- Convert to 1-based line numbers
    local col = diagnostic.col + 1 -- Convert to 1-based column numbers
    local source = diagnostic.source and string.format(" [%s]", diagnostic.source) or ""

    table.insert(content, string.format("  Line %d:%d %s%s: %s", line, col, severity, source, diagnostic.message))
  end

  callback({ content = content, context = { buf = buf }, kind = "diagnostics" })
end)

M.git_status = M.new_tool({
  name = "git_status",
  message = "Checking git status...",
  description = "Get current git status showing staged, unstaged, and untracked files",
  parameters = vim.empty_dict(),
  required = {},
  confirm = "Check git status",
}, function(args, _, callback)
  vim.system({ "git", "status", "--porcelain" }, { text = true }, function(obj)
    if obj.code ~= 0 then
      callback({ content = { "Error: Not a git repository or git not available" } })
      return
    end

    local lines = vim.split(obj.stdout or "", "\n", { trimempty = true })
    if #lines == 0 then
      callback({ content = { "Working tree clean - no changes detected" } })
      return
    end

    local content = { "Git status:", "" }
    for _, line in ipairs(lines) do
      local status = line:sub(1, 2)
      local file = line:sub(4)
      local desc = ""

      if status == "??" then
        desc = "untracked"
      elseif status == "A " then
        desc = "added"
      elseif status == "M " then
        desc = "modified"
      elseif status == " M" then
        desc = "modified (unstaged)"
      elseif status == "MM" then
        desc = "modified (staged and unstaged)"
      elseif status == "D " then
        desc = "deleted"
      else
        desc = "other"
      end

      table.insert(content, string.format("  %s: %s", desc, file))
    end

    callback({ content = content })
  end)
end)

M.git_diff = M.new_tool({
  name = "git_diff",
  message = "Getting git diff...",
  description = "Show git diff for specific files or all changes",
  parameters = {
    file = { type = "string", description = "Specific file to diff (optional)" },
    staged = { type = "boolean", description = "Show staged changes instead of unstaged" },
  },
  required = { "staged" },
  confirm = function(args)
    if args.file then
      if args.staged then
        return string.format("Show staged changes for %s", args.file)
      else
        return string.format("Show unstaged changes for %s", args.file)
      end
    else
      if args.staged then
        return "Show all staged changes"
      else
        return "Show all unstaged changes"
      end
    end
  end,
}, function(args, _, callback)
  local cmd = { "git", "diff" }

  if args.staged then
    table.insert(cmd, "--staged")
  end

  if args.file then
    table.insert(cmd, args.file)
  end

  vim.system(cmd, { text = true }, function(obj)
    if obj.code ~= 0 then
      callback({ content = { "Error running git diff" } })
      return
    end

    local lines = vim.split(obj.stdout or "", "\n")
    if #lines <= 1 then
      callback({ content = { "No changes to show" } })
      return
    end

    table.insert(lines, 1, "Git diff:")
    callback({ content = lines })
  end)
end)

M.git_commit = M.new_tool({
  name = "git_commit",
  message = "Preparing commit...",
  description = "Commit staged changes with a generated or custom commit message",
  parameters = {
    message = { type = "string", description = "Commit message" },
    files = {
      type = "array",
      items = { type = "string" },
      description = "Specific files to stage and commit (optional)",
    },
  },
  confirm = function(args)
    return string.format("Commit changes with message: '%s'", args.message)
  end,
  required = { "message" },
}, function(args, _, callback)
  local function execute_commit(message, cb)
    vim.system({ "git", "commit", "-m", message }, { text = true }, function(commit_obj)
      if commit_obj.code ~= 0 then
        cb({ content = { "Error: Commit failed", commit_obj.stderr or "Unknown error" } })
        return
      end

      local message_split = vim.split(message, "\n")
      table.insert(message_split, 1, "Successfully committed changes:")

      cb({ content = message_split })
    end)
  end

  local function proceed_with_commit()
    vim.system({ "git", "diff", "--staged", "--name-only" }, { text = true }, function(obj)
      if obj.code ~= 0 then
        callback({ content = { "Error: Not a git repository" } })
        return
      end

      local staged_files = vim.split(obj.stdout or "", "\n", { trimempty = true })
      if #staged_files == 0 then
        callback({ content = { "Error: No staged changes to commit" } })
        return
      end

      local commit_message = args.message
      execute_commit(commit_message, callback)
    end)
  end

  if args.files then
    local staged_count = 0
    local total_files = #args.files

    for _, file in ipairs(args.files) do
      vim.system({ "git", "add", file }, { text = true }, function(obj)
        staged_count = staged_count + 1
        if obj.code ~= 0 then
          callback({ content = { string.format("Error staging file: %s", file) } })
          return
        end

        if staged_count == total_files then
          proceed_with_commit()
        end
      end)
    end
  else
    proceed_with_commit()
  end
end)

M.git_unstage = M.new_tool({
  name = "git_unstage",
  message = "Unstaging files...",
  description = "Unstage files from the staging area (does not delete changes, just moves them back to unstaged)",
  parameters = {
    files = {
      type = "array",
      items = { type = "string" },
      description = "Specific files to unstage (optional - unstages all if not provided)",
    },
  },
  required = {},
  confirm = function(args)
    if args.files and #args.files > 0 then
      return string.format("Unstage files: %s", table.concat(args.files, ", "))
    else
      return "Unstage all staged files"
    end
  end,
}, function(args, _, callback)
  vim.system({ "git", "diff", "--staged", "--name-only" }, { text = true }, function(obj)
    if obj.code ~= 0 then
      callback({ content = { "Error: Not a git repository" } })
      return
    end

    local staged_files = vim.split(obj.stdout or "", "\n", { trimempty = true })
    if #staged_files == 0 then
      callback({ content = { "No staged files to unstage" } })
      return
    end

    local files_to_unstage = {}
    if args.files and #args.files > 0 then
      for _, file in ipairs(args.files) do
        local found = false
        for _, staged_file in ipairs(staged_files) do
          if file == staged_file then
            found = true
            break
          end
        end
        if found then
          table.insert(files_to_unstage, file)
        else
          callback({ content = { string.format("Warning: %s is not currently staged", file) } })
          return
        end
      end
    else
      files_to_unstage = staged_files
    end

    if #files_to_unstage == 0 then
      callback({ content = { "No valid files to unstage" } })
      return
    end

    local cmd = { "git", "reset", "HEAD" }
    for _, file in ipairs(files_to_unstage) do
      table.insert(cmd, file)
    end

    vim.system(cmd, { text = true }, function(reset_obj)
      if reset_obj.code ~= 0 then
        callback({ content = { "Error unstaging files:", reset_obj.stderr or "Unknown error" } })
        return
      end

      local content = { "Successfully unstaged files:" }
      for _, file in ipairs(files_to_unstage) do
        table.insert(content, "  " .. file)
      end

      callback({ content = content })
    end)
  end)
end)

M.show_location = M.new_tool({
  name = "show_location",
  message = "Navigating to location...",
  description = "Navigate the user's cursor to a specific location in a file for them to see",
  system_prompt = [[Navigate the user's cursor to a specific location in a file for them to see.

IMPORTANT: This tool is for directing the USER's attention to code, not for you to read code.
If you need to read file contents, use the read tool instead.

This tool is ideal for:
- Directing the user to look at a specific line of code you're discussing
- Navigating the user to error locations, function definitions, or problem areas
- Focusing the user's attention on relevant code during explanations
- Following up after grep/search results to show the user specific matches

The tool will:
- Open the file in the user's editor if not already visible
- Position the user's cursor at the exact location
- Center the line in the window for visibility
- Preserve the user's current window layout when possible

Use this when you want to say "let me show you this specific location" or "look at line X in file Y".
Do NOT use this tool to read or examine code yourself - use the read tool for that purpose.]],
  parameters = {
    file = { type = "string", description = "File path" },
    line = { type = "integer", description = "Line number (1-based)" },
    col = { type = "integer", description = "Column number (1-based, optional)" },
  },
  required = { "file", "line" },
}, function(args, _, callback)
  if not args.file then
    callback({ content = { "Error: No file path provided" } })
    return
  end

  if not args.line then
    callback({ content = { "Error: No line number provided" } })
    return
  end

  if vim.fn.filereadable(args.file) == 0 then
    callback({ content = { "Error: File cannot be found or is not readable" } })
    return
  end

  local buf = require("sia.utils").ensure_file_is_loaded(args.file)
  if not buf then
    callback({ content = { "Error: Cannot load file into buffer" } })
    return
  end

  -- Get total lines in buffer to validate line number
  local total_lines = vim.api.nvim_buf_line_count(buf)
  if args.line < 1 or args.line > total_lines then
    callback({
      content = { string.format("Error: Line %d is out of range (file has %d lines)", args.line, total_lines) },
    })
    return
  end

  -- Find a window showing this buffer, or create one
  local win = nil
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      win = w
      break
    end
  end

  if not win then
    -- Check if we're in a split layout
    local current_win = vim.api.nvim_get_current_win()
    local all_wins = vim.api.nvim_list_wins()

    if #all_wins > 1 then
      -- We have multiple windows, try to find a non-current window to use
      for _, w in ipairs(all_wins) do
        if w ~= current_win then
          vim.api.nvim_set_current_win(w)
          vim.api.nvim_set_current_buf(buf)
          win = w
          break
        end
      end
    else
      -- No splits, create a new vertical split
      vim.cmd("vsplit")
      vim.api.nvim_set_current_buf(buf)
      win = vim.api.nvim_get_current_win()
    end
  else
    -- Switch to the window showing this buffer
    vim.api.nvim_set_current_win(win)
  end

  -- Set cursor position
  local col = args.col or 1
  -- Ensure column is within line bounds
  local line_content = vim.api.nvim_buf_get_lines(buf, args.line - 1, args.line, false)[1] or ""
  col = math.min(col, #line_content + 1)

  vim.api.nvim_win_set_cursor(win, { args.line, col - 1 }) -- API uses 0-based columns

  -- Center the line in the window
  vim.cmd("normal! zz")

  local location_str = args.col and string.format("%s:%d:%d", args.file, args.line, args.col)
    or string.format("%s:%d", args.file, args.line)
  callback({ content = { string.format("Navigated to %s", location_str) } })
end)

M.show_locations = M.new_tool({
  name = "show_locations",
  message = "Creating location list...",
  description = "Show multiple locations in a navigable list for easy browsing",
  system_prompt = [[Create and display a navigable list with multiple locations for easy browsing.

This tool is perfect for:
- Showing multiple search results, errors, or locations at once
- Creating a navigable list of related code locations (e.g., all TODO comments, all function definitions)
- Presenting diagnostic results, test failures, or lint issues
- Organizing multiple findings from grep/search operations
- Creating a "table of contents" for code exploration

The location list allows users to:
- Navigate between items using :cnext/:cprev or clicking
- See all locations in one organized view
- Jump directly to any location
- Keep the list open while working on different items

Use this instead of show_location when you have:
- Multiple related locations to show (3+ items)
- Search results that should be browsed together
- A collection of errors, warnings, or findings
- Any scenario where the user benefits from seeing all locations at once

Each item should have a descriptive 'text' field explaining what's at that location.
Use appropriate 'type' values: E (error), W (warning), I (info), N (note).]],
  parameters = {
    items = {
      type = "array",
      items = {
        type = "object",
        properties = {
          filename = { type = "string", description = "File path" },
          lnum = { type = "integer", description = "Line number (1-based)" },
          col = { type = "integer", description = "Column number (1-based, optional)" },
          text = { type = "string", description = "Description text for the item" },
          type = { type = "string", description = "Item type: E (error), W (warning), I (info), N (note)" },
        },
        required = { "filename", "lnum", "text" },
      },
      description = "List of quickfix items",
    },
    title = { type = "string", description = "Title for the quickfix list" },
  },
  required = { "items" },
}, function(args, _, callback)
  if not args.items or #args.items == 0 then
    callback({ content = { "Error: No items provided for quickfix list" } })
    return
  end

  local qf_items = {}
  local valid_types = { E = true, W = true, I = true, N = true }

  for i, item in ipairs(args.items) do
    if not item.filename or not item.lnum or not item.text then
      callback({ content = { string.format("Error: Item %d missing required fields (filename, lnum, text)", i) } })
      return
    end

    local qf_item = {
      filename = item.filename,
      lnum = item.lnum,
      col = item.col or 1,
      text = item.text,
    }

    -- Validate and set type
    if item.type and valid_types[item.type] then
      qf_item.type = item.type
    end

    table.insert(qf_items, qf_item)
  end

  -- Set the quickfix list
  vim.fn.setqflist(qf_items, "r")

  -- Set title if provided
  if args.title then
    vim.fn.setqflist({}, "a", { title = args.title })
  end

  -- Open the quickfix window
  vim.cmd("copen")

  local title = args.title or "Quickfix List"
  callback({
    content = {
      string.format("Created quickfix list '%s' with %d items", title, #qf_items),
      "Use :cnext/:cprev to navigate, or click items in the quickfix window",
    },
  })
end)

M.show_recent_changes = M.new_tool({
  name = "show_recent_changes",
  message = "Showing recent changes...",
  description = "Show locations of recent changes made to files in the current session",
  system_prompt = [[Show locations of recent changes made to files in the current session.

This tool automatically tracks all modifications made through the edit tools during the current session and creates a navigable quickfix list showing exactly where changes occurred.

WHAT IT TRACKS:
- All edits made through the edit tool during this session
- Precise line numbers where changes occurred
- Type of change: additions, deletions, or modifications
- Number of lines affected for each change

WHEN TO USE:
- User asks to see where you made changes ("show me what you edited")
- User wants to navigate to recent modifications
- After making multiple edits and user wants to review them
- When user asks "where did you change that?" or similar location questions
- To create a summary of modifications made during the conversation

QUICKFIX LIST FEATURES:
- Navigate between changes using :cnext/:cprev or clicking items
- Jump directly to any change location
- See all changes organized by file and line number
- Each item shows the type and scope of change

LIMITATIONS:
- Only tracks changes made through edit tools in current session
- Changes are cleared when user saves the buffer or accepts the changes
- Does not track manual edits made by the user outside of the tool
- Only shows changes that have diff highlighting active

PARAMETERS:
- file (optional): Filter results to show only changes in a specific file

Use this tool whenever you need to show the user the locations of modifications you've made, especially after completing a series of edits.]],
  parameters = {
    file = { type = "string", description = "Specific file to show changes for (optional)" },
  },
  required = {},
}, function(args, _, callback)
  local sia = require("sia")
  local buffer_diff_state = sia.get_buffer_diff_state()

  local items = {}
  local found_changes = false

  for buf, diff_state in pairs(buffer_diff_state) do
    if diff_state.hunks and #diff_state.hunks > 0 then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      local rel_path = vim.fn.fnamemodify(buf_name, ":.")

      if args.file and not vim.endswith(rel_path, args.file) and rel_path ~= args.file then
        goto continue
      end

      found_changes = true

      for _, hunk in ipairs(diff_state.hunks) do
        local line = hunk.new_start
        local description

        if hunk.type == "add" then
          description = string.format("Added %d line(s)", hunk.new_count)
        elseif hunk.type == "delete" then
          description = string.format("Deleted %d line(s)", hunk.old_count)
        elseif hunk.type == "change" then
          description = string.format("Modified %d line(s)", hunk.new_count)
        end

        table.insert(items, {
          filename = rel_path,
          lnum = line,
          text = description,
          type = hunk.type == "add" and "I" or (hunk.type == "delete" and "W" or "N"),
        })
      end

      ::continue::
    end
  end

  if not found_changes then
    local msg = args.file and string.format("No recent changes found in %s", args.file)
      or "No recent changes found in any files"
    callback({ content = { msg } })
    return
  end

  table.sort(items, function(a, b)
    if a.filename == b.filename then
      return a.lnum < b.lnum
    end
    return a.filename < b.filename
  end)

  vim.fn.setqflist(items, "r")
  local title = args.file and string.format("Recent changes in %s", args.file) or "Recent changes in session"
  vim.fn.setqflist({}, "a", { title = title })
  vim.cmd("copen")

  callback({
    content = {
      string.format(
        "Found %d recent change(s) across %d file(s)",
        #items,
        vim.tbl_count(vim.tbl_map(function(item)
          return item.filename
        end, items))
      ),
      "Use :cnext/:cprev to navigate, or click items in the quickfix window",
    },
  })
end)

M.compact_conversation = M.new_tool({
  name = "compact_conversation",
  message = "Compacting conversation...",
  description = "Compact the conversation by summarizing previous messages when the topic changes significantly",
  system_prompt = [[Use this tool when you detect a significant topic change in
the conversation that makes previous context less relevant. This helps keep
the conversation focused and manageable.

When to use this tool:
1. The user switches from one coding task to a completely different one
2. The conversation has become very long and earlier messages are no longer relevant
3. The user explicitly asks to start fresh or change topics
4. You're working on a different part of the codebase that's unrelated to previous discussion

Do NOT use this tool:
- For minor topic shifts within the same general task
- When previous context is still relevant to the current discussion
- Early in conversations that aren't yet lengthy

The tool will preserve important context while removing outdated information.]],
  parameters = {
    reason = {
      type = "string",
      description = "Brief explanation of why the conversation needs to be compacted (e.g., 'Topic changed from debugging to new feature implementation')",
    },
  },
  required = { "reason" },
  confirm = function(args)
    return string.format("Compact conversation due to: %s", args.reason)
  end,
}, function(args, conversation, callback)
  if not args.reason then
    callback({ content = { "Error: No reason provided for compacting conversation" } })
    return
  end

  require("sia").compact_conversation(conversation, args.reason, function(content)
    if content then
      callback({
        content = {
          string.format("Successfully compacted conversation. Reason: %s", args.reason),
          "Previous context has been summarized and the conversation is now ready for the new topic.",
        },
      })
    else
      callback({ content = { "Error: Failed to compact conversation" } })
    end
  end)
end)

M.dispatch_agent = {
  name = "dispatch_agent",
  message = "Launching autonomous agent...",
  description = [[Launch a new agent that has access to the following tools: list_files, grep, read tools.
  system_prompt = [[When you are searching for a keyword or file and are not confident that you
will find the right match on the first try, use the dispatch_agent tool to perform the
search for you. For example:

1. If you want to read file, the dispatch_agent tool is NOT appropriate. If no
   appropriate tool is available ask the user to do it.
2. If you are searching for a keyword like "config" or "logger", the dispatch_agent tool is appropriate
3. If you want to read a specific file path, use the read tool
   instead of the dispatch_agent tool, to find the match more quickly
4. If you are searching for a specific class definition like "class Foo", use
   the grep tool instead, to find the match more quickly

Usage notes:

1. When a task involves multiple related queries or actions that can be
   efficiently handled together, prefer dispatching a single agent with a
   comprehensive prompt rather than multiple agents with overlapping or similar
   tasks.
2. Launch multiple agents concurrently whenever possible, to maximize
   performance; to do that, use a single message with multiple tool uses
3. When the agent is done, it will return a single message back to you. The
   result returned by the agent is not visible to the user. To show the user
   the result, you should send a text message back to the user with a concise
   summary of the result.
4. Each agent invocation is stateless. You will not be able to send additional
   messages to the agent, nor will the agent be able to communicate with you
   outside of its final report. Therefore, your prompt should contain a highly
   detailed task description for the agent to perform autonomously and you
   should specify exactly what information the agent should return back to you
   in its final and only message to you.
5. The agent's outputs should generally be trusted
6. IMPORTANT: The agent can not modify files. If you want to use these tools,
   use them directly instead of going through the agent.]],
  parameters = {
    prompt = {
      type = "string",
      description = "The task for the agent to perform",
    },
  },
  required = { "prompt" },
  execute = function(args, _, callback)
    local HiddenStrategy = require("sia.strategy").HiddenStrategy
    local Conversation = require("sia.conversation").Conversation
    local conversation = Conversation:new({
      mode = "hidden",
      system = {
        {
          role = "system",
          content = [[You are a autonomous agent. You perform the user request
and use tools to provide an answer. You cannot interact; you perform
the requested action using the tools at your disposal and provide a
response]],
        },
      },
      instructions = {
        { role = "user", content = args.prompt },
      },
      ignore_tool_confirm = true,
      tools = {
        "list_files",
        "grep",
        "read",
      },
    }, nil)
    local strategy = HiddenStrategy:new(conversation, {
      callback = function(_, reply)
        callback({ content = reply })
      end,
    })
    require("sia.assistant").execute_strategy(strategy)
  end,
}

local write_auto_apply = nil
M.write = M.new_tool({
  name = "write",
  message = "Writing file...",
  description = "Write complete file contents to a buffer (creates new file or overwrites existing)",
  system_prompt = [[Write complete file contents to a buffer.

This tool is ideal for:
- Creating new files from scratch
- Making large changes where rewriting the entire file is simpler than search/replace
- When the AI needs to restructure significant portions of a file
- Generating configuration files, templates, or boilerplate code

The tool will:
- Create a new buffer for the file if it doesn't exist
- Load and overwrite the buffer if the file already exists
- Show diff highlighting for changes made to existing files

Use this tool when:
- Creating new files
- Making extensive changes (>50% of file content)
- The search/replace approach would be too complex or error-prone
- You want to ensure the entire file structure is correct

For small, targeted changes, prefer the edit tool instead.]],
  parameters = {
    path = { type = "string", description = "The file path to write to" },
    content = { type = "string", description = "The complete file content to write" },
  },
  required = { "path", "content" },
  auto_apply = function(args)
    local file = vim.fs.basename(args.path)
    if file == "AGENTS.md" then
      return 1
    end
    return write_auto_apply
  end,
  confirm = function(args)
    if vim.fn.filereadable(args.path) == 1 then
      return string.format("Overwrite existing file %s with new content", args.path)
    else
      return string.format("Create new file %s", args.path)
    end
  end,
}, function(args, _, callback)
  if not args.path then
    callback({ content = { "Error: No file path provided" } })
    return
  end

  if not args.content then
    callback({ content = { "Error: No content provided" } })
    return
  end

  local buf = require("sia.utils").ensure_file_is_loaded(args.path)
  if not buf then
    callback({ content = { "Error: Cannot create buffer for " .. args.path } })
    return
  end

  local initial_code = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local file_exists = initial_code ~= ""

  local lines = vim.split(args.content, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  if file_exists then
    require("sia").highlight_diff_changes(buf, initial_code, args.content)
  end

  local file = vim.fs.basename(args.path)
  if file == "AGENTS.md" then
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("write")
    end)
  end

  local action = file_exists and "overwritten" or "created"
  callback({ content = { string.format("Successfully %s buffer for %s", action, args.path) } })
end)

local edit_auto_apply = nil
M.edit_file = M.new_tool({
  name = "edit",
  message = "Making code changes...",
  description = "Tool for editing files",
  system_prompt = [[This is a tool for editing files.

Before using this tool:

1. Unless the file content is available, use the read tool to understand the
   file's contents and context

To make a file edit, provide the following:
1. file_path: The path to the file to modify
2. old_string: The text to replace (must be unique within the file, and must
   match the file contents exactly, including all whitespace and indentation)
3. new_string: The edited text to replace the old_string

The tool will replace ONE occurrence of old_string with new_string in the
specified file.

CRITICAL REQUIREMENTS FOR USING THIS TOOL:

1. UNIQUENESS: The old_string MUST uniquely identify the specific instance you
   want to change. This means:
  - Include AT LEAST 3-5 lines of context BEFORE the change point
  - Include AT LEAST 3-5 lines of context AFTER the change point
  - Include all whitespace, indentation, and surrounding code exactly as it appears in the file

2. SINGLE INSTANCE: This tool can only change ONE instance at a time. If you need to change multiple instances:
  - Make separate calls to this tool for each instance
  Each call must uniquely identify its specific instance using extensive context

3. VERIFICATION: Before using this tool:
  - Check how many instances of the target text exist in the file
  - If multiple instances exist, gather enough context to uniquely identify each one
  - Plan separate tool calls for each instance

WARNING: If you do not follow these requirements:
- The tool will fail if old_string matches multiple locations
- The tool will fail if old_string doesn't match exactly (including whitespace)
- You may change the wrong instance if you don't include enough context

When making edits:
- Ensure the edit results in idiomatic, correct code
- Do not leave the code in a broken state

If you want to create a new file, use:
- A new file path, including dir name if needed
- An empty old_string
- The new file's contents as new_string

Remember: when making multiple file edits in a row to the same file, you should
prefer to send all edits in a single message with multiple calls to this tool,
rather than multiple messages with a single call each.
]],
  parameters = {

    target_file = {
      type = "string",
      description = "The file path to the file to modify",
    },
    old_string = {
      type = "string",
      description = "The text to replace",
    },
    new_string = {
      type = "string",
      description = "The text to replace with",
    },
  },
  required = { "target_file", "old_string", "new_string" },
  auto_apply = function(args)
    local file = vim.fs.basename(args.target_file)
    if file == "AGENTS.md" then
      return 1
    end
    return edit_auto_apply
  end,
  select = {
    prompt = function(args)
      return string.format("Edit %s", args.target_file)
    end,
    choices = {
      "Apply changes immediately",
      "Apply changes immediately and remember this choice",
      "Apply changes and preview them in diff view",
    },
  },
}, function(args, _, callback, choice)
  if not args.target_file then
    callback({ content = { "No target_file was provided" } })
    return
  end

  if not args.old_string then
    callback({ content = { "No old_string was provided" } })
    return
  end

  if not args.new_string then
    callback({ content = { "No new_string was provided" } })
    return
  end

  local buf = require("sia.utils").ensure_file_is_loaded(args.target_file)
  if not buf then
    callback({ content = { "Cannot load " .. args.target_file } })
    return
  end
  local matching = require("sia.matcher")

  local old_string = vim.split(args.old_string, "\n", { trimempty = true })
  local old_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local initial_code = table.concat(old_content, "\n")

  local matches
  -- Handle new file creation (empty old_string)
  if args.old_string == "" then
    -- For new files, only match if the buffer is actually empty
    if #old_content == 0 or (#old_content == 1 and old_content[1] == "") then
      -- Use 1-based indices like the matcher, will become 0, -1 in nvim_buf_set_lines
      matches = { { span = { 1, -1 } } }
    else
      matches = {} -- No match if buffer has content but old_string is empty
    end
  else
    matches = matching.find_best_subsequence_span(old_string, old_content)
  end

  if #matches == 1 then
    local new_string = vim.split(args.new_string, "\n")
    local span = matches[1].span

    if choice == 1 or choice == 2 then
      vim.api.nvim_buf_set_lines(buf, span[1] - 1, span[2], false, new_string)
      local new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local result = table.concat(new_content, "\n")
      require("sia").highlight_diff_changes(buf, initial_code, result)

      local file = vim.fs.basename(args.target_file)
      if file == "AGENTS.md" then
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("write")
        end)
      end

      if choice == 2 then
        edit_auto_apply = 1
      end
    elseif choice == 3 then
      vim.api.nvim_buf_set_lines(buf, span[1] - 1, span[2], false, new_string)
      show_diff_preview(buf, vim.split(initial_code, "\n", { plain = true, trimempty = true }))
    end

    local new_content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local result = table.concat(new_content, "\n")

    local content_lines = vim.split(result, "\n", { plain = true })
    local success_msg = string.format("Successfully edited %s. Here's the new content:", args.target_file)
    table.insert(content_lines, 1, success_msg)
    callback({ content = content_lines })
  else
    callback({ content = { string.format("Edit failed because %d matches was found", #matches) } })
  end
end)

return M
