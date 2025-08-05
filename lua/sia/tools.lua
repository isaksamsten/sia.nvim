local M = {}

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
        item = string.format("  • %s: %s in %s", kind, symbol.name, rel_path)
      else
        item = string.format("  • %s: %s", kind, symbol.name)
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

M.add_file = {
  name = "add_file",
  description = "Add a file or part of file to be included in the conversation",
  parameters = {
    path = { type = "string", description = "The file path" },
    start_line = { type = "integer", description = "The start line number" },
    end_line = { type = "integer", description = "The end line number" },
  },
  required = { "path" },
  execute = function(args, conversation, callback)
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
      confirmation = { description = { args.path } },
    })
  end,
}

--- @type sia.config.Tool
M.add_files_glob = {
  name = "add_files_glob",
  description = "Add files to the list of files to be included in the conversation",
  parameters = { glob_pattern = { type = "string", description = "Glob pattern for one or more files to be added." } },
  required = { "glob_pattern" },
  execute = function(args, conversation, callback)
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
        table.insert(message, "  • " .. file)
      end
    end

    if #missing_files > 0 then
      if #message > 0 then
        table.insert(message, "")
      end
      table.insert(message, "Unable to locate file" .. (#missing_files > 1 and "s" or "") .. ":")
      for _, file in ipairs(missing_files) do
        table.insert(message, "  • " .. file)
      end
    end

    if #message == 0 then
      callback({ content = { "No matching files found for pattern: " .. args.glob_pattern } })
    else
      local confirmation
      if #existing_files > 0 then
        confirmation = { description = existing_files }
      end
      callback({ content = message, confirmation = confirmation })
    end
  end,
}

--- @type sia.config.Tool
M.remove_file = {
  name = "remove_file",
  description = "Remove files from the list of files to be processed",
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

M.grep = {
  name = "grep",
  description = "Grep for a pattern in files using rg",
  parameters = {
    glob = { type = "string", description = "Glob pattern for files to search" },
    pattern = { type = "string", description = "Search pattern" },
  },
  required = { "pattern" },
  execute = function(args, _, callback)
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
      table.insert(lines, 1, "The following search results were returned")
      callback({ content = lines })
    end)
  end,
}

M.edit_file = {
  name = "edit_file",
  description = "Use this tool to make an edit to an existing file.\n\nThis will be read by a less intelligent model, which will quickly apply the edit. You should make it clear what the edit is, while also minimizing the unchanged code you write.\nWhen writing the edit, you should specify each edit in sequence, with the special comment // ... existing code ... to represent unchanged code in between edited lines.\n\nFor example:\n\n// ... existing code ...\nFIRST_EDIT\n// ... existing code ...\nSECOND_EDIT\n// ... existing code ...\nTHIRD_EDIT\n// ... existing code ...\n\nYou should still bias towards repeating as few lines of the original file as possible to convey the change.\nBut, each edit should contain sufficient context of unchanged lines around the code you're editing to resolve ambiguity.\nDO NOT omit spans of pre-existing code (or comments) without using the // ... existing code ... comment to indicate its absence. If you omit the existing code comment, the model may inadvertently delete these lines.\nIf you plan on deleting a section, you must provide context before and after to delete it. If the initial code is ```code \\n Block 1 \\n Block 2 \\n Block 3 \\n code```, and you want to remove Block 2, you would output ```// ... existing code ... \\n Block 1 \\n  Block 3 \\n // ... existing code ...```.\nMake sure it is clear what the edit should be, and where it should be applied.\nMake edits to a file in a single edit_file call instead of multiple edit_file calls to the same file. The apply model can handle many distinct edits at once.",
  parameters = {
    target_file = {
      type = "string",
      description = "The target file to modify.",
    },
    instructions = {
      type = "string",
      description = "A single sentence instruction describing what you are going to do for the sketched edit. This is used to assist the less intelligent model in applying the edit. Use the first person to describe what you are going to do. Use it to disambiguate uncertainty in the edit.",
    },
    code_edit = {
      type = "string",
      description = "Specify ONLY the precise lines of code that you wish to edit. NEVER specify or write out unchanged code. Instead, represent all unchanged code using the comment of the language you're editing in - example: // ... existing code ...",
    },
  },
  required = { "target_file", "instruction", "code_edit" },
  execute = function(args, _, callback)
    print(vim.inspect(args))
    if not args.target_file then
      callback({ content = { "No target_file was provided" } })
      return
    end

    if vim.fn.filereadable(args.target_file) == 0 then
      callback({ content = { "File " .. args.target_file .. " cannot be found" } })
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
        model = {
          name = "morph-v3-fast",
          function_calling = false,
        },
        provider = require("sia.provider").morph,
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
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, split)
        callback({
          content = { "I've successfully made the changes to the file " .. args.target_file },
          modified = { buf },
        })
      end
    end)
  end,
}

return M
