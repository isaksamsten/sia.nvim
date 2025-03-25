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

function M.get_kind(id)
  return KINDS[id] or "Unknown"
end

function M.is_attached(buf, method)
  local clients = vim.lsp.get_clients({ bufnr = buf, method = method })
  if vim.tbl_isempty(clients) then
    return false
  end
  return true
end

function M.request(method, opts)
  opts = opts or {}
  if opts.make_params == nil then
    error("make_params is required")
  end

  local clients = vim.lsp.get_clients({ method = method })
  if vim.tbl_isempty(clients) then
    return nil
  end
  local result = {}
  local done = {}
  for i, client in ipairs(clients) do
    local params = opts.make_params(client)

    for _, param in ipairs(params) do
      done[i] = false

      client:request(method, param, function(err, data)
        if err == nil and data ~= nil then
          local part = opts.request_handler(client, data)
          vim.list_extend(result, part)
        end
        done[i] = true
      end)
    end
  end
  vim.wait(opts.wait or 1000, function()
    return vim.iter(done):all(function(v)
      return v
    end)
  end, 10)

  return result
end

function M.document_symbols(buf, opts)
  opts = opts or {}
  return M.request("textDocument/documentSymbol", {
    make_params = function(client)
      local param = { textDocument = vim.lsp.util.make_text_document_params(buf) }
      return { param }
    end,
    request_handler = function(client, symbols)
      local result = {}
      for _, symbol in ipairs(symbols) do
        table.insert(result, symbol)
      end
      return result
    end,
    wait = opts.wait,
  })
end

function M.workspace_symbols(queries)
  return M.request("workspace/symbol", {
    make_params = function(client)
      local params = {}
      for _, query in ipairs(queries) do
        local param = vim.lsp.util.make_position_params(0, client.offset_encoding)
        --- @diagnostic disable-next-line undefined-field
        param.query = query
        table.insert(params, param)
      end
      return params
    end,
    request_handler = function(client, symbols)
      local result = {}
      for _, symbol in ipairs(symbols) do
        local uri = vim.uri_to_fname(symbol.location.uri)
        table.insert(result, { symbol = symbol, in_root = vim.startswith(uri, client.root_dir) })
      end
      return result
    end,
  })
end

return M
