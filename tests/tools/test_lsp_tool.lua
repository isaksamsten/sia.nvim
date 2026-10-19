local eq = MiniTest.expect.equality
local lsp = require("sia.tools.lsp")
local get_clients = vim.lsp.get_clients
local dir, path, conversation, requests, response

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      path = dir .. "/source.lua"
      vim.fn.writefile({ "local value = source.value", "return { x = x }" }, path)
      conversation = require("sia.conversation").new({
        workspace = dir,
        temporary = true,
        model = require("sia.model").resolve("openai/gpt-4.1"),
        approved_tools = { lsp = true },
        tools = { lsp },
      })
      requests = {}
      response = {}
      local client = {
        id = 1,
        name = "test-ls",
        offset_encoding = "utf-16",
        supports_method = function()
          return true
        end,
        request = function(_, method, params, callback, buf)
          table.insert(requests, { method = method, params = params, buf = buf })
          callback(nil, response)
          return true, #requests
        end,
      }
      vim.lsp.get_clients = function()
        return { client }
      end
    end,
    post_case = function()
      vim.lsp.get_clients = get_clients
      conversation.tracker:destroy()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf):sub(1, #dir) == dir then
          vim.diagnostic.reset(nil, buf)
          vim.api.nvim_buf_delete(buf, { force = true })
        end
      end
      vim.fn.delete(dir, "rf")
    end,
  },
})

local function run(args)
  args.path = args.path or "source.lua"
  local result
  lsp.implementation.execute(args, function(res)
    result = res
  end, { conversation = conversation })
  vim.wait(1000, function()
    return result ~= nil
  end)
  assert(result, "lsp did not finish")
  return result
end

T["unique anchor sends the matching position to the LSP"] = function()
  run({ action = "definition", line = 1, anchor = "source" })

  eq(1, #requests)
  eq("textDocument/definition", requests[1].method)
  eq({ uri = vim.uri_from_fname(path) }, requests[1].params.textDocument)
  eq({ line = 0, character = 14 }, requests[1].params.position)
  eq(path, vim.api.nvim_buf_get_name(requests[1].buf))
end

T["ambiguous anchor returns occurrence guidance without an LSP request"] = function()
  local result = run({ action = "definition", line = 2, anchor = "x" })

  eq(true, result.ephemeral)
  eq(true, result.content:find('Ambiguous anchor "x"', 1, true) ~= nil)
  eq(true, result.content:find("occurrence", 1, true) ~= nil)
  eq(0, #requests)
end

T["explicit occurrence selects the requested match"] = function()
  run({ action = "definition", line = 2, anchor = "x", occurrence = 2 })

  eq(1, #requests)
  eq({ line = 1, character = 13 }, requests[1].params.position)
end

T["definition formats Location and LocationLink results as absolute locations"] = function()
  local target = dir .. "/target.lua"
  local uri = vim.uri_from_fname(target)
  response = {
    { uri = uri, range = { start = { line = 2, character = 4 } } },
    {
      targetUri = uri,
      targetRange = { start = { line = 8, character = 0 } },
      targetSelectionRange = { start = { line = 9, character = 1 } },
    },
  }

  local result = run({ action = "definition", line = 1, anchor = "source" })

  eq(true, result.content:find(target .. ":3:5", 1, true) ~= nil)
  eq(true, result.content:find(target .. ":10:2", 1, true) ~= nil)
end

T["diagnostics returns severity, source and absolute location"] = function()
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.diagnostic.set(vim.api.nvim_create_namespace("sia-lsp-test"), buf, {
    {
      lnum = 1,
      col = 2,
      severity = vim.diagnostic.severity.ERROR,
      source = "test-ls",
      message = "bad type",
    },
  })

  local result = run({ action = "diagnostics" })

  eq(
    true,
    result.content:find(path .. ":2:3 ERROR [test-ls]: bad type", 1, true) ~= nil
  )
  eq(0, #requests)
end

return T
