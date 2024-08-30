local config = require("sia.config")
local sia = require("sia")

vim.api.nvim_create_user_command("Sia", function(args)
	if #args.fargs == 0 then
		vim.notify("No prompt")
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
		local start_pos = vim.fn.getpos("'<")
		local end_pos = vim.fn.getpos("'>")
		if end_pos[3] < 1000000 and config.options.warn_on_visual then
			vim.notify("Sia only supports visual line mode", vim.log.levels.WARN)
		end
		opts = {
			start_line = start_pos[2],
			start_col = start_pos[3],
			end_line = end_pos[2],
			end_col = end_pos[3],
			mode = "v",
		}
	end
	local prompt = sia.resolve_prompt(args.fargs, opts)
	if not prompt then
		return
	end
	if prompt.visual == true and opts.mode ~= "v" then
		vim.notify(args.fargs[1] .. " must be used in visual mode")
		return
	end
	if config._is_disabled(prompt) then
		vim.notify(args.fargs[1] .. " is not enabled")
		return
	end
	require("sia").main(prompt, opts)
end, {
	range = true,
	nargs = "+",
	complete = function(ArgLead)
		if not vim.startswith(ArgLead, "/") then
			return {}
		end
		local complete = {}
		local term = ArgLead:sub(2)
		for key, prompt in pairs(config.options.prompts) do
			if vim.startswith(key, term) and not config._is_disabled(prompt) and vim.bo.ft ~= "sia" then
				table.insert(complete, "/" .. key)
			end
		end
		return complete
	end,
})
