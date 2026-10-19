pcall(vim.treesitter.start)

local function setup_window()
  vim.opt_local.foldmethod = "expr"
  vim.opt_local.foldexpr = "v:lua.require'sia.canvas'.blockquote_foldexpr(v:lnum)"
  vim.opt_local.foldtext = "v:lua.require'sia.canvas'.blockquote_foldtext()"
  vim.opt_local.foldenable = true
  vim.opt_local.foldlevel = 0
  vim.opt_local.winhighlight:append({ Folded = "SiaFolded" })
  vim.opt_local.conceallevel = 3
  vim.opt_local.concealcursor = "n"
end

setup_window()

vim.api.nvim_create_autocmd("BufWinEnter", {
  buffer = 0,
  callback = setup_window,
})
