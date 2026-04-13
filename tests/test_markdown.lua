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
    local doc, err = markdown.parse_frontmatter_document({ "No frontmatter" })
    _G.doc = doc
    _G.err = err
  ]])

  eq(vim.NIL, child.lua_get("_G.doc"))
  eq("Invalid format: missing frontmatter", child.lua_get("_G.err"))
end

T["sia.markdown"]["read_frontmatter_file uses custom empty body error"] = function()
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
    local doc, err = markdown.read_frontmatter_file(filepath, {
      empty_body_error = "Missing custom body",
    })
    _G.doc = doc
    _G.err = err

    vim.fn.delete(tmpdir, "rf")
  ]])

  eq(vim.NIL, child.lua_get("_G.doc"))
  eq("Missing custom body", child.lua_get("_G.err"))
end

return T
