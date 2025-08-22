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

--- @type sia.config.Tool
M.find_lsp_symbol = {
  name = "find_lsp_symbol",
  description = "Search for LSP symbols and add their file and location to the context",
  parameters = {
    queries = { type = "array", items = { type = "string" }, description = "The search queries" },
  },
  required = { "queries" },
  execute = function(args, conversation, callback)
    if not args.queries or #args.queries == 0 then
      callback({ content = { "Error: No queries were provided" } })
      return
    end

    local clients = vim.lsp.get_clients({ method = "workspace/symbol" })
    if vim.tbl_isempty(clients) then
      callback({ content = { "Error: No LSP clients attached" } })
      return
    end
    local found = {}
    local done = {}
    for i, client in ipairs(clients) do
      local params = vim.lsp.util.make_position_params(0, client.offset_encoding)

      for _, query in ipairs(args.queries) do
        --- @diagnostic disable-next-line undefined-field
        params.query = query
        done[i] = false

        client:request("workspace/symbol", params, function(err, symbols)
          if err or symbols == nil then
            done[i] = true
            return
          end
          for _, symbol in ipairs(symbols) do
            local uri = vim.uri_to_fname(symbol.location.uri)
            table.insert(found, { symbol = symbol, in_root = vim.startswith(uri, client.root_dir) })
          end
          done[i] = true
        end)
      end
    end
    vim.wait(1000, function()
      return vim.iter(done):all(function(v)
        return v
      end)
    end, 10)

    local message = {}
    --- @diagnostic disable-next-line undefined-field
    conversation.lsp_symbols = conversation.lsp_symbols or {}

    for _, f in ipairs(found) do
      local symbol = f.symbol
      conversation.lsp_symbols[symbol.name] = symbol
      local rel_path = vim.fn.fnamemodify(vim.uri_to_fname(symbol.location.uri), ":.")
      local kind = KINDS[symbol.kind] or "Unkown"
      local item
      if f.in_root then
        item = string.format("  - %s: %s in %s", kind, symbol.name, rel_path)
      else
        item = string.format("  - %s: %s", kind, symbol.name)
      end

      table.insert(message, item)
    end

    if #message > 0 then
      callback({ content = message })
    else
      callback({ content = { "Error: Can't find any matching symbols" } })
    end
  end,
}

--- @type sia.config.Tool
M.documentation = {
  name = "symbol_docs",
  description = "Get the documentation for a LSP symbol resolved through find_lsp_symbol",
  parameters = { symbol = { type = "string", description = "The symbol to get documentation for" } },
  required = { "symbol" },
  execute = function(args, conversation, callback)
    if not args.symbol then
      callback({ content = { "Error: No symbol provided" } })
      return
    end

    --- @diagnostic disable-next-line undefined-field
    if conversation.lsp_symbols == nil then
      callback({ content = { "Error: No symbols have been added to the conversation yet." } })
      return
    end

    --- @diagnostic disable-next-line undefined-field
    local symbol = conversation.lsp_symbols[args.symbol]

    if symbol == nil then
      callback({ content = { "Error: The symbol " .. args.symbol .. " has not been addded to the conversation" } })
      return
    end

    local clients = vim.lsp.get_clients({ method = "textDocument/hover" })
    if vim.tbl_isempty(clients) then
      callback({ content = { "Error: No LSP clients attached" } })
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
        table.insert(found, resp)
        done[i] = true
      end)
    end

    vim.wait(1000, function()
      return vim.iter(done):all(function(v)
        return v
      end)
    end, 10)

    if #found == 0 then
      callback({ content = { "Error: No documentation found for " .. args.symbol } })
      return
    end

    local content = {}
    for _, doc in ipairs(found) do
      vim.list_extend(content, vim.lsp.util.convert_input_to_markdown_lines(doc.contents))
    end

    callback({ content = content })
  end,
}

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
        return string.format("Add lines %d-%d from %s to the conversation", args.start_line, args.end_line, args.path)
      else
        return string.format("Add lines %d-until end from %s to the conversation", args.start_line, args.path)
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
}, function(args, _, callback)
  local command = { "rg", "--column", "--no-heading", "--no-follow", "--color=never" }
  if args.glob then
    table.insert(command, "--glob")
    table.insert(command, args.glob)
  end

  if args.pattern == nil then
    callback({ content = { "No pattern was given" } })
    return
  end

  table.insert(command, "--")
  table.insert(command, args.pattern)

  vim.system(command, {
    text = true,
    stderr = false,
  }, function(obj)
    local lines = vim.split(obj.stdout, "\n")
    table.insert(lines, 1, "The following search results were returned:")
    callback({ content = lines })
  end)
end)

M.list_files = M.new_tool({
  name = "list_files",
  description = "Recursivley list files in the current project",
  message = "Exploring project structure...",
  parameters = vim.empty_dict(),
  required = {},
  confirm = "List all files in the current directory",
}, function(_, _, callback)
  vim.system({ "fd", "--type", "f" }, { text = true }, function(obj)
    local files = vim.split(obj.stdout or "", "\n", { trimempty = true })
    if #files == 0 or obj.code ~= 0 then
      callback({ content = { "No files found (or fd is not installed)." } })
      return
    end
    table.insert(files, 1, "Files in the current project (fd):")
    callback({ content = files })
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
}, function(args, _, callback)
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
  description = "Navigate to a specific location in a file and show it to the user",
  system_prompt = [[Navigate to a specific location in a file and show it to the user.

This tool is ideal for:
- Showing the user a specific line of code you're discussing
- Navigating to error locations, function definitions, or problem areas
- Directing attention to relevant code during explanations
- Following up after using grep/search tools to show specific results

The tool will:
- Open the file in a split window if not already visible
- Position the cursor at the exact location
- Center the line in the window for visibility
- Preserve the user's current window layout when possible

Use this when you want to say "let me show you this specific location" or when referencing specific lines in your explanations.]],
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

  local matches = matching.find_best_subsequence_span(old_string, old_content)
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
    local diff = vim.split(vim.diff(initial_code, result), "\n", { plain = true, trimempty = true })
    local success_msg = string.format("Successfully edited %s. Here's the resulting diff:", args.target_file)
    table.insert(diff, 1, success_msg)
    callback({ content = diff })
  else
    callback({ content = { string.format("Edit failed because %d matches was found", #matches) } })
  end
end)

return M
