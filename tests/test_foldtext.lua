local T = MiniTest.new_set()
local eq = MiniTest.expect.equality
local foldtext = require("sia.ui.foldtext")

local function text(chunks)
  return table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, chunks))
end

local function require_markdown()
  if not pcall(vim.treesitter.get_string_parser, "", "markdown_inline") then
    MiniTest.skip("markdown_inline parser is unavailable")
  end
end

T["fold previews render Markdown within arbitrary sentences"] = function()
  require_markdown()
  local chunks = foldtext.render(
    "Check **the intent**, *then* `code`, and [the docs](https://example.com)",
    100
  )
  eq("Check the intent, then code, and the docs", text(chunks))
  eq({ "the intent", { "SiaFolded", "@markup.strong.markdown_inline" } }, chunks[2])
  eq({ "then", { "SiaFolded", "@markup.italic.markdown_inline" } }, chunks[4])
  eq({ "code", { "SiaFolded", "@markup.raw.markdown_inline" } }, chunks[6])
end

T["code spans preserve literal Markdown characters"] = function()
  require_markdown()
  eq(
    "Inspect **literal** and value",
    text(foldtext.render("Inspect `**literal**` and **value**", 100))
  )
end

T["plain sentences and incomplete streaming markup remain readable"] = function()
  eq(
    { { "Consider the user's question", "SiaFolded" } },
    foldtext.render("Consider the user's question", 100)
  )
  eq("Check **unfinished", text(foldtext.render("Check **unfinished", 100)))
end

T["truncation uses rendered display width and preserves Unicode"] = function()
  require_markdown()
  eq("你好…", text(foldtext.render("**你好世界**", 4)))
  eq("Hello…", text(foldtext.render("**Hello world**", 5)))
  eq("你好", text(foldtext.render("**你好**", 4)))
  eq("éé", text(foldtext.render("**éé**", 2)))
end

T["missing Markdown parser leaves a usable plain preview"] = function()
  local saved = vim.treesitter.get_string_parser
  vim.treesitter.get_string_parser = function()
    error("unavailable")
  end
  local ok, result = pcall(foldtext.render, "**Fallback preview**", 100)
  vim.treesitter.get_string_parser = saved
  eq(true, ok)
  eq("**Fallback preview**", text(result))
end

return T
