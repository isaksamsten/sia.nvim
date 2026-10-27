vim.cmd([[let &rtp.=','.getcwd()]])

if #vim.api.nvim_list_uis() == 0 then
  require("sia").setup()
  vim.cmd("set rtp+=deps/mini.nvim")
  require("mini.test").setup()
end
