local tool_utils = require("sia.tools.utils")
local utils = require("sia.utils")
local tracker = require("sia.tracker")

local function find_column(buf, line, pattern, occurrence)
  occurrence = occurrence or 1

  local lines = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)
  if #lines == 0 then
    return nil, "Line not found"
  end
  local text = lines[1]

  -- Find the nth occurrence of the pattern
  local search_start = 1
  local count = 0

  while search_start <= #text do
    local start_col, end_col = string.find(text, pattern, search_start, true)
    if not start_col then
      break
    end

    count = count + 1
    if count == occurrence then
      return start_col - 1 -- Return 0-based column for LSP
    end

    search_start = start_col + 1 -- Move past this match to find the next one
  end

  if count == 0 then
    return nil, string.format("Pattern '%s' not found on line %d", pattern, line)
  else
    return nil,
      string.format(
        "Pattern '%s' found %d time(s) on line %d, but occurrence %d was requested",
        pattern,
        count,
        line,
        occurrence
      )
  end
end

local function lsp_buf_request(command, buf, params, callback)
  local results = {}
  local client_requests = vim.lsp.buf_request(
    buf,
    command,
    params,
    function(err, result, ctx)
      results[ctx.client_id] = { err = err, result = result }
    end
  )

  local function try_next_client()
    local key = next(client_requests)
    if key then
      local value = results[key]
      if value then
        client_requests[key] = nil
        local last_client = vim.tbl_isempty(client_requests)
        local has_content = (
          value.err == nil
          and value.result
          and value.result.contents
        )
        if last_client or has_content then
          callback(value.err, value.result)
          return
        end
      end
      vim.defer_fn(try_next_client, 30)
    else
      return -- no more clients to try
    end
  end

  try_next_client()
end

local function handle_lsp_command(command, buf, line, col, args, callback)
  local params = vim.lsp.util.make_position_params(0, "utf-8")
  params.textDocument.uri = vim.uri_from_bufnr(buf)
  params.position.line = line - 1
  params.position.character = col

  if command == "hover" then
    lsp_buf_request("textDocument/hover", buf, params, function(err, result)
      if err then
        callback({ content = { "LSP Error: " .. vim.inspect(err) }, kind = "failed" })
        return
      end
      if not result or not result.contents then
        callback({ content = { "No hover information found." }, kind = "lsp_result" })
        return
      end
      local markdown_lines =
        vim.lsp.util.convert_input_to_markdown_lines(result.contents)
      if vim.tbl_isempty(markdown_lines) then
        callback({ content = { "No hover information found." }, kind = "lsp_result" })
        return
      end
      callback({
        content = markdown_lines,
        kind = "lsp_result",
        display_content = {
          string.format("🔧 Got documentation for '%s'", args.pattern),
        },
      })
    end)
  elseif
    command == "definition"
    or command == "references"
    or command == "implementation"
    or command == "type_definition"
  then
    local method = "textDocument/" .. command
    if command == "references" then
      params.context = {
        includeDeclaration = true,
      }
    end
    lsp_buf_request(method, buf, params, function(err, result)
      if err then
        callback({ content = { "LSP Error: " .. vim.inspect(err) }, kind = "failed" })
        return
      end
      if not result or vim.tbl_isempty(result) then
        callback({ content = { "No locations found." }, kind = "lsp_result" })
        return
      end

      if not vim.islist(result) then
        result = { result }
      end

      local locations = {}
      for _, loc in ipairs(result) do
        local uri = loc.uri or loc.targetUri
        local range = loc.range or loc.targetSelectionRange
        local location_filename = vim.uri_to_fname(uri)
        local lnum = range.start.line + 1
        table.insert(
          locations,
          string.format("%s:%d", vim.fn.fnamemodify(location_filename, ":."), lnum)
        )
      end

      local command_label = command:gsub("_", " ")
      callback({
        content = locations,
        kind = "lsp_result",
        display_content = {
          string.format(
            "🔧 Found %d %s for '%s'",
            #locations,
            #locations == 1 and command_label or command_label .. "s",
            args.pattern
          ),
        },
      })
    end)
  elseif command == "rename" then
    if not args.new_name then
      callback({
        content = { "Error: new_name is required for rename command" },
        kind = "failed",
      })
      return
    end
    params.newName = args.new_name
    lsp_buf_request("textDocument/rename", buf, params, function(err, result)
      if err then
        callback({ content = { "LSP Error: " .. vim.inspect(err) }, kind = "failed" })
        return
      end
      if not result then
        callback({
          content = { "No rename performed (LSP returned nil)." },
          kind = "lsp_result",
        })
        return
      end

      vim.lsp.util.apply_workspace_edit(result, "utf-8")

      local modified_files = {}
      if result.changes then
        for uri, _ in pairs(result.changes) do
          table.insert(modified_files, vim.uri_to_fname(uri))
        end
      end
      if result.documentChanges then
        for _, change in ipairs(result.documentChanges) do
          local uri
          if change.textDocument then
            uri = change.textDocument.uri
          elseif
            change.kind == "create"
            or change.kind == "rename"
            or change.kind == "delete"
          then
            uri = change.uri
          end
          if uri then
            table.insert(modified_files, vim.uri_to_fname(uri))
          end
        end
      end

      -- Save modified buffers to ensure grep still works
      for _, file in ipairs(modified_files) do
        local b = vim.fn.bufnr(file)
        if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
          vim.api.nvim_buf_call(b, function()
            pcall(vim.cmd, "noa silent write!")
          end)
        end
      end

      local num_files = #modified_files
      local file_list = num_files > 0
          and table.concat(
            vim.tbl_map(function(f)
              return vim.fn.fnamemodify(f, ":.")
            end, modified_files),
            ", "
          )
        or "unknown files"

      callback({
        content = {
          string.format(
            "Renamed '%s' to '%s' in %d file%s: %s",
            args.pattern,
            args.new_name,
            num_files,
            num_files == 1 and "" or "s",
            file_list
          ),
        },
        kind = "lsp_result",
        display_content = {
          string.format(
            "🔧 Renamed '%s' → '%s' in %d file%s",
            args.pattern,
            args.new_name,
            num_files,
            num_files == 1 and "" or "s"
          ),
        },
      })
    end)
  else
    callback({ content = { "Unknown command: " .. command }, kind = "failed" })
  end
end

return tool_utils.new_tool({
  name = "lsp",
  read_only = false,
  message = "Querying LSP...",
  description = "Use LSP server capabilities (hover, definition, references, rename, etc.)",
  system_prompt = [[Use this tool to query the Language Server Protocol (LSP).
Supported commands:
- hover: Get documentation for the symbol at the location.
- definition: Find the definition of the symbol.
- references: Find references to the symbol.
- implementation: Find implementations of the symbol.
- type_definition: Find the type definition of the symbol.
- rename: Rename the symbol (requires new_name).

You must provide the file path, line number, and a pattern (symbol name) to identify the exact column.
If the same pattern appears multiple times on the line, specify which occurrence.
The pattern will match as a substring, so 'x' will match 'x' in 'xy' - be specific with your pattern if needed.]],
  parameters = {
    command = {
      type = "string",
      enum = {
        "hover",
        "definition",
        "references",
        "implementation",
        "type_definition",
        "rename",
      },
      description = "The LSP command to execute",
    },
    path = { type = "string", description = "The file path" },
    line = { type = "integer", description = "The line number (1-based)" },
    pattern = {
      type = "string",
      description = "The symbol name or unique string to locate on the line",
    },
    occurrence = {
      type = "integer",
      description = "Which occurrence of the pattern to use. Default is 1.",
    },
    new_name = {
      type = "string",
      description = "The new name (required for rename command)",
    },
  },
  required = { "command", "path", "line", "pattern" },
}, function(args, _, callback)
  local buf = utils.ensure_file_is_loaded(args.path, { listed = false })
  if not buf then
    callback({
      content = { "Error: Could not load file " .. args.path },
      kind = "failed",
    })
    return
  end

  local col, err = find_column(buf, args.line, args.pattern, args.occurrence)
  if not col then
    callback({ content = { "Error: " .. err }, kind = "failed" })
    return
  end

  handle_lsp_command(args.command, buf, args.line, col, args, callback)
end)
