local M = {}
function M.get_window_for_buffer(buf)
	local windows = vim.api.nvim_tabpage_list_wins(0)
	for _, win in ipairs(windows) do
		if vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
	return nil
end

return M
