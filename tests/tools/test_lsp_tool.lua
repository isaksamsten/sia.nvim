local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local function ok(value)
  if not value then
    error("expected truthy value", 2)
  end
end

T["sia.tools.lsp"] = MiniTest.new_set()

T["sia.tools.lsp"]["find_anchor resolves unique anchor"] = function()
  local lsp = require("sia.tools.lsp")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local value = source.value" })

  local col, err = lsp._private.find_anchor(buf, 1, "source")

  eq(14, col)
  eq(nil, err)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tools.lsp"]["find_anchor reports ambiguous matches with occurrence guidance"] = function()
  local lsp = require("sia.tools.lsp")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "return { x = x }" })

  local col, err = lsp._private.find_anchor(buf, 1, "x")

  eq(nil, col)
  ok(err:find('Ambiguous anchor "x"', 1, true) ~= nil)
  ok(err:find("occurrence", 1, true) ~= nil)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tools.lsp"]["find_anchor resolves requested occurrence"] = function()
  local lsp = require("sia.tools.lsp")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "return { x = x }" })

  local col, err = lsp._private.find_anchor(buf, 1, "x", 2)

  eq(13, col)
  eq(nil, err)
  vim.api.nvim_buf_delete(buf, { force = true })
end

T["sia.tools.lsp"]["normalizes LSP Location and LocationLink results"] = function()
  local lsp = require("sia.tools.lsp")
  local uri = vim.uri_from_fname(vim.fn.getcwd() .. "/lua/example.lua")

  local locations = lsp._private.normalize_locations({
    { uri = uri, range = { start = { line = 2, character = 4 } } },
    {
      targetUri = uri,
      targetSelectionRange = { start = { line = 9, character = 1 } },
    },
  })

  eq(2, #locations)
  eq(3, locations[1].line)
  eq(5, locations[1].column)
  eq(10, locations[2].line)
  eq(2, locations[2].column)
end

T["sia.tools.lsp"]["formats diagnostics with clickable locations"] = function()
  local lsp = require("sia.tools.lsp")
  local buf = vim.api.nvim_create_buf(false, true)
  local path = vim.fn.getcwd() .. "/tmp_lsp_test.lua"
  vim.api.nvim_buf_set_name(buf, path)
  vim.diagnostic.set(vim.api.nvim_create_namespace("sia-lsp-test"), buf, {
    {
      lnum = 1,
      col = 2,
      severity = vim.diagnostic.severity.ERROR,
      source = "test-ls",
      message = "bad type",
    },
  })

  local content, count = lsp._private.format_diagnostics(buf, path)

  eq(1, count)
  ok(content:find("tmp_lsp_test.lua:2:3 ERROR %[test%-ls%]: bad type") ~= nil)
  vim.diagnostic.reset(nil, buf)
  vim.api.nvim_buf_delete(buf, { force = true })
end

return T

