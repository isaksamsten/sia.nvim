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
      callback({ "Error: No queries were provided" })
      return
    end

    local clients = vim.lsp.get_clients({ method = "workspace/symbol" })
    if vim.tbl_isempty(clients) then
      callback({ "Error: No LSP clients attached" })
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
      callback(message)
    else
      callback({ "Error: Can't find any matching symbols" })
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
      callback({ "Error: No symbol provided" })
      return
    end

    --- @diagnostic disable-next-line undefined-field
    if conversation.lsp_symbols == nil then
      callback({ "Error: No symbols have been added to the conversation yet." })
      return
    end

    --- @diagnostic disable-next-line undefined-field
    local symbol = conversation.lsp_symbols[args.symbol]

    if symbol == nil then
      callback({ "Error: The symbol " .. args.symbol .. " has not been addded to the conversation" })
      return
    end

    local clients = vim.lsp.get_clients({ method = "textDocument/hover" })
    if vim.tbl_isempty(clients) then
      callback({ "Error: No LSP clients attached" })
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
      callback({ "Error: No documentation found for " .. args.symbol })
      return
    end

    local content = {}
    for _, doc in ipairs(found) do
      vim.list_extend(content, vim.lsp.util.convert_input_to_markdown_lines(doc.contents))
    end

    callback(content)
  end,
}

--- @type sia.config.Tool
M.add_file = {
  name = "add_file",
  description = "Add files to the list of files to be included in the conversation",
  parameters = { glob_pattern = { type = "string", description = "Glob pattern for one or more files to be added." } },
  required = { "glob_pattern" },
  execute = function(args, conversation, callback)
    if not args.glob_pattern then
      callback({ "Error: No glob pattern provided." })
      return
    end

    local files = require("sia.utils").glob_pattern_to_files(args.glob_pattern)
    if #files > 3 then
      callback({ "Error: Glob pattern matches too many files (> 3). Please provide a more specific pattern." })
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
      callback({ "No matching files found for pattern: " .. args.glob_pattern })
    else
      local confirmation
      if #existing_files > 0 then
        confirmation = { description = existing_files }
      end
      callback(message, confirmation)
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
      callback({ "I've removed the files matching " .. args.glob_pattern .. " from the conversation." })
    else
      callback({ "The glob pattern is missing" })
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
      callback({ "No pattern was given" })
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
      callback(lines)
    end)
  end,
}

return M
