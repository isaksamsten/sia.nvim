local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      child.restart({ "-u", "assets/minimal.lua" })
    end,
    post_once = function()
      child.stop()
    end,
  },
})

local eq = MiniTest.expect.equality

T["sia.markdown"] = MiniTest.new_set()

T["sia.markdown"]["parse_frontmatter_document parses metadata and body"] = function()
  child.lua([[
    local markdown = require("sia.markdown")
    local doc, err = markdown.parse_frontmatter_document({
      "---",
      "name: sample",
      "description: Sample document",
      "tools:",
      "  - grep",
      "---",
      "",
      "# Heading",
    })
    _G.doc = doc
    _G.err = err
  ]])

  local doc = child.lua_get("_G.doc")
  local err = child.lua_get("_G.err")

  eq(vim.NIL, err)
  eq("sample", doc.metadata.name)
  eq("Sample document", doc.metadata.description)
  eq({ "grep" }, doc.metadata.tools)
  eq({ "", "# Heading" }, doc.body)
end

T["sia.markdown"]["parse_frontmatter_document reports missing frontmatter"] = function()
  child.lua([[
    local markdown = require("sia.markdown")
    local ok, doc = pcall(markdown.parse_frontmatter_document, { "No frontmatter" })
    _G.ok = ok
    _G.doc = doc
  ]])

  eq(false, child.lua_get("_G.ok"))
  eq(true, child.lua_get("_G.doc"):find("Invalid format: missing frontmatter", 1, true) ~= nil)
end

T["sia.markdown"]["read_frontmatter_file reports empty body"] = function()
  child.lua([[
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local filepath = tmpdir .. "/sample.md"
    vim.fn.writefile({
      "---",
      "name: sample",
      "---",
    }, filepath)

    local markdown = require("sia.markdown")
    local ok, doc = pcall(markdown.read_frontmatter_file, filepath)
    _G.ok = ok
    _G.doc = doc

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(false, child.lua_get("_G.ok"))
  eq(true, child.lua_get("_G.doc"):find("Missing markdown body", 1, true) ~= nil)
end

return T
