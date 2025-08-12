local M = {}

---@class SiaNewToolOpts
---@field name string
---@field description string
---@field auto_apply (fun(args: table):integer?)?
---@field message string?
---@field required string[]
---@field parameters table
---@field confirm (string|fun(args:table):string)?
---@field select { prompt: (string|fun(args:table):string)?, choices: string[]}?

--- @type table<string, boolean?>
local auto_confirm = {}

---@param opts SiaNewToolOpts
---@param execute any
---@return sia.config.Tool
M.new_tool = function(opts, execute)
  local auto_apply = opts.auto_apply
    or function(_)
      if auto_confirm[opts.name] then
        return 1
      else
        return nil
      end
    end

  return {
    name = opts.name,
    message = opts.message,
    parameters = opts.parameters,
    description = opts.description,
    required = opts.required,
    execute = function(args, strategy, callback)
      if opts.confirm ~= nil then
        if auto_apply(args) then
          execute(args, strategy, callback)
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
              callback({ content = string.format("User cancelled %s operation.", opts.name) })
              return
            end

            local response = resp:lower()
            if response == "a" or response == "always" then
              auto_confirm[opts.name] = true
              execute(args, strategy, callback)
            elseif response == "n" or response == "no" then
              callback({ content = string.format("User declined to execute %s.", opts.name) })
            else
              execute(args, strategy, callback)
            end
          end
        )
      elseif opts.select then
        local auto_applied_choice = auto_apply(args)
        if auto_applied_choice then
          execute(args, strategy, callback, auto_applied_choice)
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
              if idx == nil then
                callback({ content = string.format("User cancelled %s operation.", opts.name) })
                return
              end
              execute(args, strategy, callback, idx)
            end
          )
        end
      else
        execute(args, strategy, callback)
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

M.add_file = M.new_tool({
  name = "add_file",
  message = "Reading file contents...",
  description = [[Add a file or part of file to be included in the conversation.
- If adding a part of the file, specify both start_line and end_line.
- If adding a complete file, skip both start_line and end_line.
]],
  parameters = {
    path = { type = "string", description = "The file path" },
    start_line = { type = "integer", description = "The start line number. Ignore if adding the complete file." },
    end_line = { type = "integer", description = "The end line number. Ignore if adding the complete file." },
  },
  required = { "path" },
  confirm = function(args)
    if args.start_line and args.end_line then
      return string.format("Add lines %d-%d from %s to the conversation", args.start_line, args.end_line, args.path)
    end
    return string.format("Add %s to the conversation", args.path)
  end,
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
  if args.start_line and args.end_line then
    pos = { args.start_line, args.end_line }
  end

  conversation:add_file({ path = args.path, pos = pos })
  callback({
    content = { "I've added " .. args.path .. " to the conversation" },
  })
end)

--- @type sia.config.Tool
M.add_files_glob = M.new_tool({
  name = "add_files_glob",
  message = "Loading multiple files...",
  description = "Add files to the list of files to be included in the conversation",
  parameters = { glob_pattern = { type = "string", description = "Glob pattern for one or more files to be added." } },
  required = { "glob_pattern" },
  confirm = function(args)
    return string.format("Add all files matching pattern '%s' to the conversation", args.glob_pattern)
  end,
}, function(args, conversation, callback)
  if not args.glob_pattern then
    callback({ content = { "Error: No glob pattern provided." } })
    return
  end

  local files = require("sia.utils").glob_pattern_to_files(args.glob_pattern)
  if #files > 3 then
    callback({
      content = { "Error: Glob pattern matches too many files (> 3). Please provide a more specific pattern." },
    })
    return
  end

  local missing_files = {}
  local existing_files = {}
  for _, file in ipairs(files) do
    if vim.fn.filereadable(file) == 0 then
      table.insert(missing_files, file)
    else
      table.insert(existing_files, file)
      conversation:add_file(file)
    end
  end

  local message = {}
  if #existing_files > 0 then
    table.insert(message, "Successfully added file" .. (#existing_files > 1 and "s" or "") .. ":")
    for _, file in ipairs(existing_files) do
      table.insert(message, "  - " .. file)
    end
  end

  if #missing_files > 0 then
    if #message > 0 then
      table.insert(message, "")
    end
    table.insert(message, "Unable to locate file" .. (#missing_files > 1 and "s" or "") .. ":")
    for _, file in ipairs(missing_files) do
      table.insert(message, "  - " .. file)
    end
  end

  if #message == 0 then
    callback({ content = { "No matching files found for pattern: " .. args.glob_pattern } })
  else
    callback({ content = message })
  end
end)

--- @type sia.config.Tool
M.remove_file = {
  name = "remove_file",
  description = "Remove files from the conversation",
  parameters = { glob_pattern = { type = "string", description = "Glob pattern for one or more files to be deleted." } },
  required = { "glob_pattern" },
  execute = function(args, conversation, callback)
    if args.glob_pattern then
      conversation:remove_files({ args.glob_pattern })
      callback({ content = { "I've removed the files matching " .. args.glob_pattern .. " from the conversation." } })
    else
      callback({ content = { "The glob pattern is missing" } })
    end
  end,
}

M.grep = M.new_tool({
  name = "grep",
  message = "Searching through files...",
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

M.edit_file = M.new_tool({
  name = "edit_file",
  message = "Making code changes...",
  description = [[Edit an existing file by specifying precise changes.

KEY PRINCIPLES:
- Make ALL edits to a file in a single tool call (use multiple edit blocks if needed)
- Only specify lines you're changing - represent unchanged code with comments

EDIT SYNTAX:
Use "... existing code ..." comments to represent unchanged sections:

// ...
  existing code ...
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
const updated = "new value";  // was: const old = "old value";
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
        local timestamp = os.date("%H:%M:%S")
        vim.cmd("tabnew")
        local left_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(
          left_buf,
          0,
          -1,
          false,
          vim.split(initial_code, "\n", { plain = true, trimempty = true })
        )
        vim.api.nvim_buf_set_name(
          left_buf,
          string.format("%s [ORIGINAL @ %s]", vim.api.nvim_buf_get_name(buf), timestamp)
        )
        vim.bo[left_buf].buftype = "nofile"
        vim.bo[left_buf].buflisted = false
        vim.bo[left_buf].swapfile = false
        vim.bo[left_buf].ft = vim.bo[buf].ft

        vim.cmd("vsplit")
        local right_win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(right_win, buf)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, split)
        vim.api.nvim_set_current_win(right_win)
        vim.cmd("diffthis")
        vim.api.nvim_set_current_win(vim.fn.win_getid(vim.fn.winnr("#")))
        vim.cmd("diffthis")
        vim.bo[left_buf].modifiable = false
        vim.api.nvim_set_current_win(right_win)
      end
      local diff = vim.split(vim.diff(initial_code, result), "\n", { plain = true, trimempty = true })
      local success_msg = string.format("Successfully edited %s. Here's the resulting diff:", args.target_file)
      table.insert(diff, 1, success_msg)
      callback({
        content = diff,
        modified = { buf },
      })
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
    callback({ content = { string.format("No diagnostics found for %s", args.file) } })
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

  callback({ content = content })
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

M.agent = {
  name = "call_agent",
  description = "Outsoure a task to another model",
  parameters = {
    model = {},
  },
}

return M
