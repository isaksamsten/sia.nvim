local M = {}

local LSP_KINDS = { Function = { 12, 6 }, Class = { 5, 10, 23 }, Interface = { 11 } }
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

M.find_lsp_symbol = {
  name = "find_lsp_symbol",
  description = "Search for LSP symbols and add their file and location to the context",
  parameters = {
    kind = { type = "string", description = "The kind of symbol: Class, Function or Interface" },
    query = { type = "string", description = "The search query" },
  },
  required = { "query" },
  execute = function(args, strategy, callback)
    if not args.query then
      callback({ "Error: No query was provided" })
      return
    end

    local clients = vim.lsp.get_clients({ method = "workspace/symbol" })
    if vim.tbl_isempty(clients) then
      callback({ "Error: No LSP clients attached" })
      return
    end
    local wanted_kinds = LSP_KINDS[args.kind] or { 12, 6, 5, 10, 23, 11 }
    local found = {}
    local done = {}
    for i, client in ipairs(clients) do
      local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
      params.query = args.query
      done[i] = false

      client:request("workspace/symbol", params, function(err, resp)
        if err then
          done[i] = true
          return
        end
        for _, r in ipairs(resp) do
          if args.kind == nil or vim.tbl_contains(wanted_kinds, r.kind) then
            local uri = vim.uri_to_fname(r.location.uri)
            if vim.startswith(uri, client.root_dir) then
              table.insert(found, r)
            end
          end
        end
        done[i] = true
      end)
    end
    vim.wait(1000, function()
      return vim.iter(done):all(function(v)
        return v
      end)
    end, 10)

    local message = {}
    for _, symbol in ipairs(found) do
      local rel_path = vim.fn.fnamemodify(vim.uri_to_fname(symbol.location.uri), ":.")
      local kind = KINDS[symbol.kind] or "Unkown"
      table.insert(message, string.format("  • %s: %s in %s", kind, symbol.name, rel_path))
    end

    if #message > 0 then
      callback(message)
    else
      callback({ "Error: Can't find any matching symbols" })
    end
  end,
}

--- @type sia.config.Tool
M.add_file = {
  name = "add_file",
  description = "Add files to the list of files to be included in the conversation",
  parameters = { glob_pattern = { type = "string", description = "Glob pattern for one or more files to be added." } },
  required = { "glob_pattern" },
  execute = function(args, split, callback)
    --- @cast split sia.SplitStrategy
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
        split:add_file(file)
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
  execute = function(args, split, callback)
    if args.glob_pattern then
      --- @cast split sia.SplitStrategy
      split:remove_files({ args.glob_pattern })
      callback({ "I've removed the files matching " .. args.glob_pattern .. " from the conversation." })
    else
      callback({ "The glob pattern is missing" })
    end
  end,
}

return M
