local dante = {}

function dante.setup(options)
	require("dante.config").setup(options)
end

function dante.main(line1, line2)
	vim.cmd("set diffopt=internal,filler,closeoff,vertical,algorithm:patience,followwrap,linematch:120")

	-- Request
	local req_buf = vim.api.nvim_get_current_buf()
	local req_win = vim.api.nvim_get_current_win()
	vim.cmd("diffthis")
	vim.api.nvim_buf_set_option(req_buf, "filetype", "tex")
	vim.api.nvim_win_set_option(req_win, "wrap", true)
	vim.api.nvim_win_set_option(req_win, "linebreak", true)

	-- Response
	vim.cmd("vsplit")
	local res_win = vim.api.nvim_get_current_win()
	local res_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(res_win, res_buf)
	vim.api.nvim_buf_set_option(res_buf, "filetype", "tex")
	vim.api.nvim_win_set_option(res_win, "wrap", true)
	vim.api.nvim_win_set_option(res_win, "linebreak", true)

	-- Focus back to request window
	vim.api.nvim_set_current_win(req_win)

	-- Query
	require("dante.assistant").query(line1, line2, res_buf, res_win)
end

return dante