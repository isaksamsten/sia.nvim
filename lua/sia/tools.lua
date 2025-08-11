local M = {}

local diff_ns = vim.api.nvim_create_namespace("sia_diff_highlights")
-- Track extmarks per buffer with their line positions for selective clearing
local diff_extmarks = {}

---@param buf number Buffer handle
---@param old_content string Original content
---@param new_content string New content after changes
local function highlight_diff_changes(buf, old_content, new_content)
  -- TODO: use vim.text.diff
  local diff_result = vim.text.diff(old_content, new_content, {
    result_type = "indices",
    algorithm = "myers",
  })

  if not diff_result then
    return
  end

  -- Initialize tracking for this buffer if needed
  if not diff_extmarks[buf] then
    diff_extmarks[buf] = {}
  end

  -- Collect line ranges that will be affected by new extmarks
  local affected_lines = {}
  for _, hunk in ipairs(diff_result) do
    local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]

    -- Lines that will have virtual lines above them (for deleted content)
    if old_count > 0 then
      local line_idx = math.max(0, new_start - 1)
      affected_lines[line_idx] = true
    end

    -- Lines that will be highlighted (for added/changed content)
    if new_count > 0 then
      for i = 0, new_count - 1 do
        local line_idx = new_start - 1 + i
        affected_lines[line_idx] = true
      end
    end
  end

  -- Clear only extmarks on lines that will be affected by new highlights
  for line_idx in pairs(affected_lines) do
    if diff_extmarks[buf][line_idx] then
      for _, extmark_id in ipairs(diff_extmarks[buf][line_idx]) do
        vim.api.nvim_buf_del_extmark(buf, diff_ns, extmark_id)
      end
      diff_extmarks[buf][line_idx] = nil
    end
  end

  local old_lines = vim.split(old_content, "\n", { plain = true })

  for _, hunk in ipairs(diff_result) do
    local old_start, old_count, new_start, new_count = hunk[1], hunk[2], hunk[3], hunk[4]

    if old_count > 0 then
      local old_text_lines = {}
      for i = 0, old_count - 1 do
        local old_line_idx = old_start + i
        if old_line_idx <= #old_lines then
          table.insert(old_text_lines, old_lines[old_line_idx])
        end
      end

      local line_idx = math.max(0, new_start - 1)
      if line_idx <= vim.api.nvim_buf_line_count(buf) then
        local virt_lines = {}
        for _, old_line in ipairs(old_text_lines) do
          table.insert(virt_lines, { { old_line, "DiffDelete" } })
        end

        local extmark_id = vim.api.nvim_buf_set_extmark(buf, diff_ns, line_idx, 0, {
          virt_lines = virt_lines,
          virt_lines_above = true,
          priority = 100,
        })
        if not diff_extmarks[buf][line_idx] then
          diff_extmarks[buf][line_idx] = {}
        end
        table.insert(diff_extmarks[buf][line_idx], extmark_id)
      end
    end

    if new_count > 0 then
      for i = 0, new_count - 1 do
        local line_idx = new_start - 1 + i
        if line_idx < vim.api.nvim_buf_line_count(buf) then
          local hl_group = (old_count > 0) and "DiffChange" or "DiffAdd"
          local extmark_id = vim.api.nvim_buf_set_extmark(buf, diff_ns, line_idx, 0, {
            end_col = 0,
            hl_group = hl_group,
            line_hl_group = hl_group,
            priority = 100,
          })
          if not diff_extmarks[buf][line_idx] then
            diff_extmarks[buf][line_idx] = {}
          end
          table.insert(diff_extmarks[buf][line_idx], extmark_id)
        end
      end
    end
  end

  local augroup = vim.api.nvim_create_augroup("sia_diff_clear_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    buffer = buf,
    once = true,
    callback = function()
      vim.api.nvim_buf_clear_namespace(buf, diff_ns, 0, -1)
      vim.api.nvim_del_augroup_by_id(augroup)
    end,
  })
end

---@class SiaNewToolOpts
---@field name string
---@field description string
---@field auto_apply (fun():integer?)?
---@field message string?
---@field required string[]
---@field parameters table
---@field confirm (string|fun(args:table):string)?
---@field select { prompt: (string|fun(args:table):string)?, choices: string[]}?

---@param opts SiaNewToolOpts
---@param execute any
---@return sia.config.Tool
M.new_tool = function(opts, execute)
  local auto_apply = opts.auto_apply or function()
    return nil
  end

  return {
    name = opts.name,
    message = opts.message,
    parameters = opts.parameters,
    description = opts.description,
    required = opts.required,
    execute = function(args, strategy, callback)
      if opts.confirm ~= nil then
        local text
        if type(opts.confirm) == "function" then
          text = opts.confirm(args)
        else
          text = opts.confirm
        end
        vim.ui.input(
          { prompt = string.format("%s\nProceed? [Y/n] (default: Yes, Esc to cancel): ", text) },
          function(resp)
            if resp ~= nil and resp:lower() ~= "y" and resp:lower() ~= "yes" and resp ~= "" then
              callback({ content = string.format("User declined to execute %s.", opts.name) })
              return
            end
            execute(args, strategy, callback)
          end
        )
      elseif opts.select then
        local auto_applied_choice = auto_apply()
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
  description = "Add a file or part of file to be included in the conversation",
  parameters = {
    path = { type = "string", description = "The file path" },
    start_line = { type = "integer", description = "The start line number" },
    end_line = { type = "integer", description = "The end line number" },
  },
  required = { "path" },
  confirm = function(args)
    return string.format("Sia want's to add the file %s", args.path)
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
    return string.format("Sia wants to add all files matching %s", args.glob_pattern)
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
    local text = string.format("Sia wants search for %s", args.pattern)
    if args.glob then
      text = string.format("%s in files matching %s", text, args.glob)
    end
    return text
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
  confirm = "Sia want to list all files in CWD",
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
  description = [[Use this tool to make an edit to an existing file.

This will be read by a less intelligent model, which will quickly apply the
edit. You should make it clear what the edit is, while also minimizing the
unchanged code you write.
When writing the edit, you should specify each
edit in sequence, with the special comment // ... existing code ... to
represent unchanged code in between edited lines.

For example:

// ...
  existing code ...
FIRST_EDIT
// ... existing code ...
SECOND_EDIT
// ...
  existing code ...
THIRD_EDIT
// ... existing code ...

You should still bias towards repeating as few lines of the original file as
possible to convey the change. But, each edit should contain sufficient context
of unchanged lines around the code you're editing to resolve ambiguity.

DO NOT omit spans of pre-existing code (or comments) without using the // ...
existing code ... comment to indicate its absence. If you omit the existing
code comment, the model may inadvertently delete these lines. If you plan on
deleting a section, you must provide context before and after to delete it.
If the initial code is, ```code
 Block 1
 Block 2
 Block 3
code```, and you want to remove Block 2, you would output
```// ... existing code ...
 Block 1
 Block 3
 // ... existing code ...
```.
Make sure it is clear what the edit should be, and where it should be applied.
Make edits to a file in a single edit_file call instead of multiple edit_file
calls to the same file. The apply model can handle many distinct edits at
once.]],
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
  auto_apply = function()
    return edit_file_auto_apply
  end,
  select = {
    prompt = function(args)
      if args.instructions then
        return string.format("%s\nReady to edit %s?", args.instructions, args.target_file)
      else
        return string.format("Ready to edit %s?", args.target_file)
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
        highlight_diff_changes(buf, initial_code, result)

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

M.agent = {
  name = "call_agent",
  description = "Outsoure a task to another model",
  parameters = {
    model = {},
  },
}

return M
