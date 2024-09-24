-- Define a variable to track whether we're inside a valid code block
local M = {}

local config = require("sia.config").options
local utils = require("sia.utils")

local ns_flash_id = vim.api.nvim_create_namespace("sia_flash") -- Create a namespace for the highlight
local ns_bind_id = vim.api.nvim_create_namespace("sia_bind")

local ignore_ft = {
	"help",
	"man",
	"git",
	"fugitive",
	"netrw",
	"log",
	"packer",
	"dashboard",
	"TelescopePrompt",
	"NvimTree",
	"vista",
	"terminal",
	"diff",
	"qf",
	"lspinfo",
	"harpoon",
	"outline",
	"sia",
	"neotest-summary",
	"neotest-output-panel",
}

local function flash_highlight(bufnr, start_line, end_line, timeout, hl_group)
	for line = start_line, end_line do
		vim.api.nvim_buf_add_highlight(bufnr, ns_flash_id, hl_group, line, 0, -1)
	end

	local timer = vim.loop.new_timer()
	timer:start(
		timeout,
		0,
		vim.schedule_wrap(function()
			vim.api.nvim_buf_clear_namespace(bufnr, ns_flash_id, start_line, end_line + 1)
			timer:stop()
			timer:close()
		end)
	)
end

local code_blocks = {}

local function select_other_buffer(current_buf, callback)
	local other = {}
	local tab_wins = vim.api.nvim_tabpage_list_wins(0)
	for _, win in ipairs(tab_wins) do
		local buf = vim.api.nvim_win_get_buf(win)
		if
			buf ~= current_buf
			and vim.api.nvim_buf_is_loaded(buf)
			and not vim.tbl_contains(other, function(v)
				return v.buf == buf
			end, { predicate = true })
		then
			local ft = vim.api.nvim_buf_get_option(buf, "filetype")
			if not vim.list_contains(ignore_ft, ft) then
				local name = vim.api.nvim_buf_get_name(buf)
				table.insert(other, { buf = buf, win = win, name = name })
			end
		end
	end
	if #other == 0 then
		return
	elseif #other == 1 then
		callback(other[1])
	else
		vim.ui.select(other, {
			format_item = function(item)
				return item.name
			end,
		}, function(choice)
			callback(choice)
		end)
	end
end

local function attach_keybinding(buf, opts)
	vim.api.nvim_buf_clear_namespace(buf, ns_bind_id, 0, -1)
	local virt_text = "Press `ga` to insert"
	if opts.start_range and opts.end_range and opts.buf then
		vim.keymap.set("n", config.default.replace.map.replace, function()
			local lines = vim.api.nvim_buf_get_lines(buf, opts.start_block, opts.end_block - 1, false)
			local source_line_count = #lines
			if vim.api.nvim_buf_is_loaded(opts.buf) then
				vim.api.nvim_buf_set_lines(opts.buf, opts.start_range - 1, opts.end_range, false, lines)
				flash_highlight(
					opts.buf,
					opts.start_range - 1,
					opts.start_range + source_line_count - 1,
					config.default.replace.timeout,
					config.default.replace.highlight
				)
			end
		end, { buffer = buf, noremap = false, silent = true })
		if vim.api.nvim_buf_is_loaded(opts.buf) then
			local full_path = vim.api.nvim_buf_get_name(opts.buf)
			local file_name = vim.fn.fnamemodify(full_path, ":t")
			virt_text = string.format(
				"Press `ga` to insert or `gr` to replace line %s to %s in %s",
				opts.start_range,
				opts.end_range,
				file_name
			)
		end
	end

	vim.keymap.set("n", config.default.replace.map.insert, function()
		local lines = vim.api.nvim_buf_get_lines(buf, opts.start_block, opts.end_block - 1, false)
		local source_line_count = #lines
		if opts.buf and vim.api.nvim_buf_is_loaded(opts.buf) then
			local win = utils.get_window_for_buffer(opts.buf)
			if win then
				local start_range, _ = unpack(vim.api.nvim_win_get_cursor(win))
				if start_range == 1 then
					start_range = 0
				end
				vim.api.nvim_buf_set_lines(opts.buf, start_range, start_range, false, lines)
				flash_highlight(
					opts.buf,
					start_range,
					start_range + source_line_count,
					config.default.replace.timeout,
					config.default.replace.highlight
				)
				return
			end
		end

		-- if the LLM generated bad destination buffer or if no buffer was provided.
		select_other_buffer(buf, function(other)
			if other then
				local start_range, _ = unpack(vim.api.nvim_win_get_cursor(other.win))
				if start_range == 1 then
					start_range = 0
				end
				vim.api.nvim_buf_set_lines(other.buf, start_range, start_range, false, lines)
				flash_highlight(
					other.buf,
					start_range,
					start_range + source_line_count,
					config.default.replace.timeout,
					config.default.replace.highlight
				)
			end
		end)
	end, { buffer = buf, noremap = false, silent = true })
	vim.api.nvim_buf_set_extmark(buf, ns_bind_id, opts.start_block - 1, 0, {
		virt_text = { { virt_text, "Comment" } },
	})
end

local function remove_keybinding(bufnr)
	pcall(function()
		vim.api.nvim_buf_del_keymap(bufnr, "n", config.default.replace.map.replace)
	end)
	pcall(function()
		vim.api.nvim_buf_del_keymap(bufnr, "n", config.default.replace.map.insert)
	end)
	vim.api.nvim_buf_clear_namespace(bufnr, ns_bind_id, 0, -1)
end

function M.check_if_in_code_block(bufnr)
	local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
	if code_blocks[bufnr] then
		for i, block in ipairs(code_blocks[bufnr]) do
			if row >= block.start_block and row <= block.end_block then
				attach_keybinding(bufnr, block)
				return
			end
		end
	end
	remove_keybinding(bufnr)
end

function M.detect_code_blocks(buf)
	M.remove_code_blocks(buf)
	local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
	local current_code_block = nil
	for i, line in ipairs(lines) do
		if current_code_block == nil then
			local orig_buf, start_range, end_range =
				string.match(line, "^%s*```.+%s+(%d+)%s+replace%-range:(%d+),(%d+)")
			if orig_buf and start_range and end_range then
				current_code_block = {
					start_block = i,
					start_range = tonumber(start_range),
					end_range = tonumber(end_range),
					buf = tonumber(orig_buf),
				}
			elseif string.match(line, "^%s*```%w+%s*$") then
				current_code_block = {
					start_block = i,
				}
			end
		else
			if string.match(line, "^%s*```%s*$") then
				current_code_block.end_block = i
				if code_blocks[buf] then
					table.insert(code_blocks[buf], current_code_block)
				else
					code_blocks[buf] = { current_code_block }
				end
				current_code_block = nil
			end
		end
	end
end

function M.remove_code_blocks(buf)
	code_blocks[buf] = nil
end

return M
