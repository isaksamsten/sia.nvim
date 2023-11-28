vim.api.nvim_create_user_command("Dante", function(args)
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)
	local prompt = "default"
	if args.args ~= "" then
		prompt = args.args
	end
	require("dante").main(prompt, lines, args.line1, args.line2)
end, {
	range = true,
	nargs = "?",
	complete = function(ArgLead)
		local complete = {}
		for prompt, _ in pairs(require("dante.config").options.prompts) do
			if #ArgLead == 0 or prompt:sub(1, #ArgLead) == #ArgLead then
				table.insert(complete, prompt)
			end
		end
		return complete
	end,
})
