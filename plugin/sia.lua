local config = require("sia.config")
local sia = require("sia")

vim.api.nvim_create_user_command("Sia", function(args)
	if #args.fargs == 0 and not vim.b.sia then
		vim.notify("No prompt")
		return
	end

	local opts
	if args.count == -1 then
		opts = {
			start_line = args.line1,
			start_col = 0,
			end_line = args.line2,
			end_col = 0,
			mode = "n",
		}
	else
		opts = {
			start_line = args.line1,
			start_col = 0,
			end_line = args.line2,
			end_col = 0,
			mode = "v",
		}
	end
	opts.force_insert = args.bang
	local prompt
	if vim.b.sia then
		prompt = sia.resolve_prompt({ vim.b.sia }, opts)
	else
		prompt = sia.resolve_prompt(args.fargs, opts)
	end
	if not prompt then
		return
	end
	if prompt.range == true and opts.mode ~= "v" then
		vim.notify(args.fargs[1] .. " must be used with a range")
		return
	end
	if config._is_disabled(prompt) then
		vim.notify(args.fargs[1] .. " is not enabled")
		return
	end
	require("sia").main(prompt, opts)
end, {
	range = true,
	bang = true,
	nargs = "*",
	complete = function(ArgLead)
		-- Get the current command line input and type
		local cmd_type = vim.fn.getcmdtype() -- ":" indicates Ex commands
		local cmd_line = vim.fn.getcmdline() -- Full command line input

		-- Initialize a flag to detect if the command starts with a range, accounting for leading spaces
		local is_range = false

		-- Check only for Ex commands (":")
		if cmd_type == ":" then
			-- Define patterns to match range forms at the start of the command line, allowing for leading spaces
			local range_patterns = {
				"^%s*%d+", -- Single line number (start), with optional leading spaces
				"^%s*%d+,%d+", -- Line range (start,end), with optional leading spaces
				"^%s*%d+[,+-]%d+", -- Line range with arithmetic (start+1, start-1)
				"^%s*%d+,", -- Line range with open end (start,), with optional leading spaces
				"^%s*%%", -- Whole file range (%), with optional leading spaces
				"^%s*[$.]+", -- $, ., etc., with optional leading spaces
				"^%s*[$.%d]+[%+%-]?%d*", -- Combined offsets (e.g., .+1, $-1)
				"^%s*'[a-zA-Z]", -- Marks ('a, 'b), etc.
				"^%s*[%d$%.']+,[%d$%.']+", -- Mixed patterns (e.g., ., 'a)
				"^%s*['<>][<>]", -- Visual selection marks ('<, '>)
				"^%s*'<[,]'?>", -- Combinations like '<,'>
			}

			-- Check if the command line starts with any of the range patterns
			for _, pattern in ipairs(range_patterns) do
				if cmd_line:match(pattern) then
					is_range = true
					break
				end
			end
		end

		if not vim.startswith(ArgLead, "/") then
			return {}
		end
		local complete = {}
		local term = ArgLead:sub(2)
		for key, prompt in pairs(config.options.prompts) do
			if
				vim.startswith(key, term)
				and (prompt.range == nil or prompt.range == is_range)
				and not config._is_disabled(prompt)
				and vim.bo.ft ~= "sia"
			then
				table.insert(complete, "/" .. key)
			end
		end
		return complete
	end,
})
