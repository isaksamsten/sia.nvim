local tool_utils = require("sia.tools.utils")
local utils = require("sia.utils")
local icons = require("sia.ui").icons

local POSITION_ACTION_METHODS = {
  explain = "textDocument/hover",
  definition = "textDocument/definition",
  references = "textDocument/references",
  implementations = "textDocument/implementation",
  type_definition = "textDocument/typeDefinition",
  rename = "textDocument/rename",
  code_actions = "textDocument/codeAction",
}

local LOCATION_ACTIONS = {
  definition = true,
  references = true,
  implementations = true,
  type_definition = true,
}

local MUTATING_ACTIONS = {
  rename = true,
  code_actions = true,
  format = true,
}

local ACTION_LABELS = {
  explain = "explanation",
  definition = "definition",
  references = "references",
  implementations = "implementations",
  type_definition = "type definition",
  rename = "rename",
  diagnostics = "diagnostics",
  symbols = "symbols",
  workspace_symbols = "workspace symbols",
  code_actions = "code actions",
  format = "format",
  clients = "clients",
}

local function is_blank(value)
  return value == nil or value == ""
end

local function relative_path(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

local function line_text(buf, line)
  local lines = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)
  return lines[1]
end

local function find_anchor(buf, line, anchor, occurrence)
  local text = line_text(buf, line)
  if not text then
    return nil, string.format("Line %d does not exist", line)
  end

  local matches = {}
  local start_at = 1
  while start_at <= #text do
    local start_col = text:find(anchor, start_at, true)
    if not start_col then
      break
    end
    table.insert(matches, start_col)
    start_at = start_col + 1
  end

  if #matches == 0 then
    return nil,
      string.format(
        'Anchor "%s" was not found on line %d. Line text:\n%s',
        anchor,
        line,
        text
      )
  end

  if occurrence then
    if occurrence < 1 or occurrence > #matches then
      return nil,
        string.format(
          'Anchor "%s" has %d match%s on line %d, but occurrence=%d was requested. Line text:\n%s',
          anchor,
          #matches,
          #matches == 1 and "" or "es",
          line,
          occurrence,
          text
        )
    end
    return matches[occurrence] - 1
  end

  if #matches > 1 then
    local lines = {
      string.format(
        'Ambiguous anchor "%s" on line %d. Found %d matches:',
        anchor,
        line,
        #matches
      ),
    }
    for idx, col in ipairs(matches) do
      table.insert(lines, string.format("%d. column %d: %s", idx, col, text))
    end
    table.insert(lines, "Call again with occurrence set to the intended match number.")
    return nil, table.concat(lines, "\n")
  end

  return matches[1] - 1
end

local function get_clients(buf, method)
  local clients = vim.lsp.get_clients({ bufnr = buf, method = method })
  if #clients == 0 then
    clients = vim.lsp.get_clients({ bufnr = buf })
    if method then
      clients = vim.tbl_filter(function(client)
        return client.supports_method and client:supports_method(method, buf)
      end, clients)
    end
  end
  return clients
end

local function client_encoding(client)
  return client and client.offset_encoding or "utf-16"
end

local function make_position_params(buf, line, col)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = line - 1, character = col },
  }
end

local function make_range_params(buf, line, col)
  return {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    range = {
      start = { line = line - 1, character = col or 0 },
      ["end"] = { line = line - 1, character = col or 0 },
    },
    context = {
      diagnostics = vim.diagnostic.get(buf, { lnum = line - 1 }),
    },
  }
end

local function request_first(buf, method, params, callback)
  local clients = get_clients(buf, method)
  if #clients == 0 then
    callback(string.format("No attached LSP client supports %s", method))
    return
  end

  local pending = #clients
  local last_empty
  for _, client in ipairs(clients) do
    client:request(method, params, function(err, result)
      pending = pending - 1
      if err then
        callback("LSP error from " .. client.name .. ": " .. vim.inspect(err))
        return
      end

      local empty = result == nil
        or (type(result) == "table" and vim.tbl_isempty(result))
      if not empty then
        callback(nil, result, client)
        return
      end

      last_empty = client
      if pending == 0 then
        callback(nil, nil, last_empty)
      end
    end, buf)
  end
end

local function request_all(buf, method, params, callback)
  local clients = get_clients(buf, method)
  if #clients == 0 then
    callback(string.format("No attached LSP client supports %s", method))
    return
  end

  local pending = #clients
  local results = {}
  for _, client in ipairs(clients) do
    client:request(method, params, function(err, result)
      pending = pending - 1
      table.insert(results, { client = client, err = err, result = result })
      if pending == 0 then
        callback(nil, results)
      end
    end, buf)
  end
end

local function normalize_locations(result)
  if not result then
    return {}
  end
  if not vim.islist(result) then
    result = { result }
  end

  local locations = {}
  for _, loc in ipairs(result) do
    local uri = loc.uri or loc.targetUri
    local range = loc.range or loc.targetSelectionRange or loc.targetRange
    if uri and range then
      table.insert(locations, {
        path = vim.uri_to_fname(uri),
        line = range.start.line + 1,
        column = range.start.character + 1,
      })
    end
  end
  return locations
end

local function location_lines(locations)
  local lines = {}
  for _, loc in ipairs(locations) do
    table.insert(
      lines,
      string.format("%s:%d:%d", relative_path(loc.path), loc.line, loc.column)
    )
  end
  return lines
end

local function format_diagnostics(buf, path)
  local diagnostics = vim.diagnostic.get(buf)
  if #diagnostics == 0 then
    return "No diagnostics found for " .. relative_path(path), 0
  end

  local severity_names = {
    [vim.diagnostic.severity.ERROR] = "ERROR",
    [vim.diagnostic.severity.WARN] = "WARNING",
    [vim.diagnostic.severity.INFO] = "INFO",
    [vim.diagnostic.severity.HINT] = "HINT",
  }
  local lines = { "Diagnostics for " .. relative_path(path) .. ":", "" }
  for _, diagnostic in ipairs(diagnostics) do
    local source = diagnostic.source and (" [" .. diagnostic.source .. "]") or ""
    table.insert(
      lines,
      string.format(
        "%s:%d:%d %s%s: %s",
        relative_path(path),
        diagnostic.lnum + 1,
        diagnostic.col + 1,
        severity_names[diagnostic.severity] or "UNKNOWN",
        source,
        diagnostic.message
      )
    )
  end
  return table.concat(lines, "\n"), #diagnostics
end

local function flatten_symbols(symbols, out, path, depth)
  out = out or {}
  depth = depth or 0
  for _, symbol in ipairs(symbols or {}) do
    local name = symbol.name or "<unnamed>"
    local kind = symbol.kind and vim.lsp.protocol.SymbolKind[symbol.kind] or "Symbol"
    local range = symbol.selectionRange
      or symbol.range
      or (symbol.location and symbol.location.range)
    local uri = symbol.location and symbol.location.uri
    local symbol_path = uri and vim.uri_to_fname(uri) or path
    local line = range and (range.start.line + 1) or 1
    local col = range and (range.start.character + 1) or 1
    table.insert(
      out,
      string.format(
        "%s%s [%s] %s:%d:%d",
        string.rep("  ", depth),
        name,
        kind,
        relative_path(symbol_path),
        line,
        col
      )
    )
    if symbol.children then
      flatten_symbols(symbol.children, out, path, depth + 1)
    end
  end
  return out
end

local function format_clients(buf)
  local clients = vim.lsp.get_clients({ bufnr = buf })
  if #clients == 0 then
    return "No LSP clients are attached to this buffer.", 0
  end

  local lines = { "Attached LSP clients:" }
  for _, client in ipairs(clients) do
    local methods = {}
    for _, method in pairs(POSITION_ACTION_METHODS) do
      if client.supports_method and client:supports_method(method, buf) then
        table.insert(methods, method)
      end
    end
    table.sort(methods)
    table.insert(
      lines,
      string.format(
        "- %s (id=%d, offset_encoding=%s): %s",
        client.name,
        client.id,
        client_encoding(client),
        #methods > 0 and table.concat(methods, ", ") or "no v1 position methods"
      )
    )
  end
  return table.concat(lines, "\n"), #clients
end

local function collect_workspace_edit_files(edit)
  local files = {}
  local seen = {}
  local function add(uri)
    if uri and not seen[uri] then
      seen[uri] = true
      table.insert(files, vim.uri_to_fname(uri))
    end
  end

  if edit.changes then
    for uri, _ in pairs(edit.changes) do
      add(uri)
    end
  end
  if edit.documentChanges then
    for _, change in ipairs(edit.documentChanges) do
      if change.textDocument then
        add(change.textDocument.uri)
      elseif change.uri then
        add(change.uri)
      elseif change.oldUri then
        add(change.oldUri)
      elseif change.newUri then
        add(change.newUri)
      end
    end
  end
  return files
end

local function save_files(files)
  for _, file in ipairs(files) do
    local buf = vim.fn.bufnr(file)
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_call(buf, function()
        pcall(vim.cmd, "noa silent write!")
      end)
    end
  end
end

local function apply_workspace_edit(edit, client, save)
  vim.lsp.util.apply_workspace_edit(edit, client_encoding(client))
  local files = collect_workspace_edit_files(edit)
  if save then
    save_files(files)
  end
  return files
end

local function code_action_title(action)
  return action.title or action.command or "<untitled>"
end

local function resolve_code_action(actions, args)
  if args.title then
    for _, action in ipairs(actions) do
      if code_action_title(action) == args.title then
        return action
      end
    end
    return nil, 'No code action matched title "' .. args.title .. '"'
  end

  if args.index then
    if args.index < 1 or args.index > #actions then
      return nil, string.format("Code action index %d is out of range", args.index)
    end
    return actions[args.index]
  end

  return nil, "Set index or title to apply a specific code action."
end

local function apply_code_action(action, client, callback, save)
  if action.edit then
    local files = apply_workspace_edit(action.edit, client, save)
    callback(nil, files)
    return
  end

  local command = action.command
  if type(command) == "table" then
    client:request("workspace/executeCommand", command, function(err)
      callback(err and vim.inspect(err) or nil, {})
    end)
  elseif type(command) == "string" then
    local params = { command = command, arguments = action.arguments }
    client:request("workspace/executeCommand", params, function(err)
      callback(err and vim.inspect(err) or nil, {})
    end)
  else
    callback("Selected code action has no edit or command")
  end
end

local function run_explain(buf, params, args, callback)
  request_first(buf, "textDocument/hover", params, function(err, result)
    if err then
      callback({ content = "Error: " .. err, ephemeral = true })
      return
    end
    if not result or not result.contents then
      callback({ content = "No explanation found.", ephemeral = true })
      return
    end
    local lines = vim.lsp.util.convert_input_to_markdown_lines(result.contents)
    if vim.tbl_isempty(lines) then
      callback({ content = "No explanation found.", ephemeral = true })
      return
    end
    callback({
      content = table.concat(lines, "\n"),
      summary = string.format("%s Explained '%s'", icons.lsp, args.anchor),
    })
  end)
end

local function run_locations(action, buf, params, args, callback)
  if action == "references" then
    params.context = { includeDeclaration = true }
  end

  request_first(buf, POSITION_ACTION_METHODS[action], params, function(err, result)
    if err then
      callback({ content = "Error: " .. err, ephemeral = true })
      return
    end
    local locations = normalize_locations(result)
    if #locations == 0 then
      callback({ content = "No locations found.", ephemeral = true })
      return
    end

    callback({
      content = table.concat(location_lines(locations), "\n"),
      summary = string.format(
        "%s Found %d %s for '%s'",
        icons.lsp,
        #locations,
        ACTION_LABELS[action],
        args.anchor
      ),
    })
  end)
end

local function run_rename(buf, params, args, callback)
  if is_blank(args.new_name) then
    callback({ content = "Error: new_name is required for rename", ephemeral = true })
    return
  end
  params.newName = args.new_name

  request_first(buf, "textDocument/rename", params, function(err, result, client)
    if err then
      callback({ content = "Error: " .. err, ephemeral = true })
      return
    end
    if not result then
      callback({ content = "No rename edit returned.", ephemeral = true })
      return
    end

    local files = collect_workspace_edit_files(result)
    if not args.apply then
      local lines = { "Rename preview. Set apply=true to apply this edit.", "" }
      if #files == 0 then
        table.insert(lines, "Modified files: unknown")
      else
        table.insert(lines, "Modified files:")
        for _, file in ipairs(files) do
          table.insert(lines, "- " .. relative_path(file))
        end
      end
      callback({ content = table.concat(lines, "\n") })
      return
    end

    files = apply_workspace_edit(result, client, args.save ~= false)
    callback({
      content = string.format(
        "Renamed '%s' to '%s' in %d file%s: %s",
        args.anchor,
        args.new_name,
        #files,
        #files == 1 and "" or "s",
        #files > 0 and table.concat(vim.tbl_map(relative_path, files), ", ")
          or "unknown"
      ),
      summary = string.format("%s Renamed '%s'", icons.lsp, args.anchor),
    })
  end)
end

local function run_diagnostics(buf, path, callback)
  local content, count = format_diagnostics(buf, path)
  callback({
    content = content,
    summary = string.format("%s Found %d diagnostics", icons.diagnostics, count),
  })
end

local function run_symbols(buf, path, callback)
  local params = { textDocument = { uri = vim.uri_from_bufnr(buf) } }
  request_first(buf, "textDocument/documentSymbol", params, function(err, result)
    if err then
      callback({ content = "Error: " .. err, ephemeral = true })
      return
    end
    local lines = flatten_symbols(result or {}, {}, path)
    if #lines == 0 then
      callback({ content = "No document symbols found.", ephemeral = true })
      return
    end
    callback({
      content = table.concat(lines, "\n"),
      summary = string.format("%s Found %d symbols", icons.lsp, #lines),
    })
  end)
end

local function run_workspace_symbols(buf, query, callback)
  if is_blank(query) then
    callback({
      content = "Error: query is required for workspace_symbols",
      ephemeral = true,
    })
    return
  end
  request_first(buf, "workspace/symbol", { query = query }, function(err, result)
    if err then
      callback({ content = "Error: " .. err, ephemeral = true })
      return
    end
    local lines = flatten_symbols(result or {}, {}, nil)
    if #lines == 0 then
      callback({ content = "No workspace symbols found.", ephemeral = true })
      return
    end
    callback({
      content = table.concat(lines, "\n"),
      summary = string.format("%s Found %d workspace symbols", icons.lsp, #lines),
    })
  end)
end

local function run_code_actions(buf, params, args, callback)
  request_all(buf, "textDocument/codeAction", params, function(err, responses)
    if err then
      callback({ content = "Error: " .. err, ephemeral = true })
      return
    end

    local actions = {}
    for _, response in ipairs(responses) do
      if response.err then
        callback({
          content = "Error from " .. response.client.name .. ": " .. vim.inspect(
            response.err
          ),
          ephemeral = true,
        })
        return
      end
      for _, action in ipairs(response.result or {}) do
        table.insert(actions, { action = action, client = response.client })
      end
    end

    if #actions == 0 then
      callback({ content = "No code actions found.", ephemeral = true })
      return
    end

    if not args.apply then
      local lines =
        { "Code actions. Set apply=true with index or title to apply one.", "" }
      for idx, item in ipairs(actions) do
        table.insert(
          lines,
          string.format("%d. %s", idx, code_action_title(item.action))
        )
      end
      callback({
        content = table.concat(lines, "\n"),
        summary = string.format("%s Found %d code actions", icons.lsp, #actions),
      })
      return
    end

    local selected, select_err = resolve_code_action(
      vim.tbl_map(function(item)
        return item.action
      end, actions),
      args
    )
    if not selected then
      callback({ content = "Error: " .. select_err, ephemeral = true })
      return
    end

    local selected_client
    for _, item in ipairs(actions) do
      if item.action == selected then
        selected_client = item.client
        break
      end
    end

    apply_code_action(selected, selected_client, function(apply_err, files)
      if apply_err then
        callback({ content = "Error: " .. apply_err, ephemeral = true })
        return
      end
      callback({
        content = string.format(
          "Applied code action: %s%s",
          code_action_title(selected),
          #files > 0
              and ("\nModified files: " .. table.concat(
                vim.tbl_map(relative_path, files),
                ", "
              ))
            or ""
        ),
        summary = string.format("%s Applied code action", icons.lsp),
      })
    end, args.save ~= false)
  end)
end

local function run_format(buf, args, callback)
  local clients = get_clients(buf, "textDocument/formatting")
  if #clients == 0 then
    callback({
      content = "Error: No attached LSP client supports formatting",
      ephemeral = true,
    })
    return
  end

  if not args.apply then
    callback({
      content = "Formatting is mutating. Set apply=true to format the file.",
      ephemeral = true,
    })
    return
  end

  vim.lsp.buf.format({ bufnr = buf, timeout_ms = args.timeout_ms or 10000 })
  if args.save ~= false then
    vim.api.nvim_buf_call(buf, function()
      pcall(vim.cmd, "noa silent write!")
    end)
  end
  callback({
    content = "Formatted " .. relative_path(vim.api.nvim_buf_get_name(buf)),
    summary = string.format("%s Formatted file", icons.lsp),
  })
end

local function load_buffer(args, conversation, read_only)
  if is_blank(args.path) then
    return nil, "Error: path is required"
  end
  local path = tool_utils.resolve_workspace_path(args.path, conversation.workspace)
  local buf =
    utils.ensure_file_is_loaded(path, { listed = false, read_only = read_only })
  if not buf then
    return nil, "Error: Could not load file " .. args.path
  end
  return buf, nil, path
end

local function requires_anchor(action)
  return POSITION_ACTION_METHODS[action] ~= nil
end

local function execute(args, conversation, callback)
  local action = args.action
  if is_blank(action) then
    callback({ content = "Error: action is required", ephemeral = true })
    return
  end

  local needs_file = action ~= "workspace_symbols"
  local buf, load_err, path
  if needs_file then
    buf, load_err, path = load_buffer(args, conversation, not MUTATING_ACTIONS[action])
    if load_err then
      callback({ content = load_err, ephemeral = true })
      return
    end
  else
    local current = vim.api.nvim_get_current_buf()
    buf = current
  end

  if action == "clients" then
    local content, count = format_clients(buf)
    callback({
      content = content,
      summary = string.format("%s Found %d LSP clients", icons.lsp, count),
    })
    return
  elseif action == "diagnostics" then
    run_diagnostics(buf, path, callback)
    return
  elseif action == "symbols" then
    run_symbols(buf, path, callback)
    return
  elseif action == "workspace_symbols" then
    run_workspace_symbols(buf, args.query, callback)
    return
  elseif action == "format" then
    run_format(buf, args, callback)
    return
  end

  if not requires_anchor(action) then
    callback({ content = "Error: Unknown action: " .. action, ephemeral = true })
    return
  end

  if is_blank(args.line) then
    callback({ content = "Error: line is required for " .. action, ephemeral = true })
    return
  end
  if is_blank(args.anchor) then
    callback({ content = "Error: anchor is required for " .. action, ephemeral = true })
    return
  end

  local col, anchor_err = find_anchor(buf, args.line, args.anchor, args.occurrence)
  if not col then
    callback({ content = "Error: " .. anchor_err, ephemeral = true })
    return
  end

  if action == "code_actions" then
    run_code_actions(buf, make_range_params(buf, args.line, col), args, callback)
    return
  end

  local params = make_position_params(buf, args.line, col)
  if action == "explain" then
    run_explain(buf, params, args, callback)
  elseif LOCATION_ACTIONS[action] then
    run_locations(action, buf, params, args, callback)
  elseif action == "rename" then
    run_rename(buf, params, args, callback)
  end
end

local M = tool_utils.new_tool({
  definition = {
    type = "function",
    name = "lsp",
    description = "Use Neovim LSP features with simple line + anchor targeting",
    parameters = {
      action = {
        type = "string",
        enum = {
          "explain",
          "definition",
          "references",
          "implementations",
          "type_definition",
          "rename",
          "diagnostics",
          "symbols",
          "workspace_symbols",
          "code_actions",
          "format",
          "clients",
        },
        description = "The LSP action to run",
      },
      path = { type = "string", description = "File path for file/buffer actions" },
      line = {
        type = "integer",
        description = "1-based line number for symbol actions",
      },
      anchor = {
        type = "string",
        description = "Exact text to find on the target line for symbol actions",
      },
      occurrence = {
        type = "integer",
        description = "Use the nth anchor match when the anchor appears multiple times on the line",
      },
      query = {
        type = "string",
        description = "Search query for workspace_symbols",
      },
      new_name = {
        type = "string",
        description = "New symbol name for rename",
      },
      apply = {
        type = "boolean",
        description = "Apply mutating actions. Defaults to false for previews/lists.",
      },
      save = {
        type = "boolean",
        description = "Save modified buffers after applying edits. Defaults to true.",
      },
      index = {
        type = "integer",
        description = "Code action index to apply after listing code actions",
      },
      title = {
        type = "string",
        description = "Code action title to apply after listing code actions",
      },
    },
    required = { "action" },
  },
  read_only = false,
  summary = function(args)
    local label = args and ACTION_LABELS[args.action] or nil
    return label and ("Running LSP " .. label .. "...") or "Running LSP..."
  end,
  instructions = [[Use Neovim's attached Language Server Protocol clients.

Actions:
- explain: Get documentation/type information for a symbol.
- definition: Find where a symbol is defined.
- references: Find symbol references.
- implementations: Find implementations of an interface/abstract symbol.
- type_definition: Find the type definition of a symbol.
- rename: Rename a symbol. Requires new_name. Preview by default; set apply=true to edit files.
- diagnostics: List diagnostics for a file.
- symbols: List document symbols for a file.
- workspace_symbols: Search workspace symbols. Requires query.
- code_actions: List code actions for a line anchor. Set apply=true with index or title to apply one.
- format: Format a file. Requires apply=true.
- clients: List attached LSP clients for a file.

For symbol actions, provide path, line, and anchor. The anchor is exact text on that line. If it appears multiple times, the tool returns numbered matches; call again with occurrence set to the desired number. Do not guess column numbers.]],
  persist_allow = function(args)
    return tool_utils.path_allow_rules("path", args.path)
  end,
}, execute)

M._private = {
  find_anchor = find_anchor,
  normalize_locations = normalize_locations,
  format_diagnostics = format_diagnostics,
  flatten_symbols = flatten_symbols,
  collect_workspace_edit_files = collect_workspace_edit_files,
}

return M
