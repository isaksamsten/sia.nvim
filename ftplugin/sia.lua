pcall(vim.treesitter.start)

local function setup_window()
  vim.opt_local.foldmethod = "expr"
  vim.opt_local.foldexpr = "v:lua.require'sia.canvas'.blockquote_foldexpr(v:lnum)"
  vim.opt_local.foldenable = true
  vim.opt_local.foldlevel = 0
  vim.opt_local.conceallevel = 3
  vim.opt_local.concealcursor = "n"

  for _, m in ipairs(vim.fn.getmatches()) do
    if m.group == "Conceal" and m.pattern == [[^>|\%( \)\?]] then
      return
    end
  end
  vim.fn.matchadd("Conceal", [[^>|\%( \)\?]], 10, -1)
end

setup_window()

vim.api.nvim_create_autocmd("BufWinEnter", {
  buffer = 0,
  callback = setup_window,
})
