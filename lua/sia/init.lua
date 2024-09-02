local config = require("sia.config")

local sia = {}

function sia.setup(options)
	require("sia.config").setup(options)
	vim.treesitter.language.register("markdown", "sia")
end

local function replace_named_prompts(prompts)
	for i, prompt in ipairs(prompts) do
		if type(prompt) ~= "table" then
			prompts[i] = vim.deepcopy(config.options.named_prompts[prompt])
		end
	end
	return prompts
end

--- @return table|nil
function sia.resolve_prompt(prompt, opts)
	if vim.startswith(prompt[1], "/") and vim.bo.ft ~= "sia" then
		local prompt_key = prompt[1]:sub(2)
		local prompt_config = vim.deepcopy(config.options.prompts[prompt_key])
		if prompt_config == nil then
			vim.notify(prompt[1] .. " does not exists")
			return nil
		end

		if prompt_config.input and prompt_config.input == "require" and #prompt < 2 then
			vim.notify(prompt[1] .. " requires input")
			return nil
		end

		if #prompt > 1 and not (prompt_config.input and prompt_config.input == "ignore") then
			table.insert(prompt_config.prompt, { role = "user", content = table.concat(prompt, " ", 2) })
		end
		prompt_config.prompt = replace_named_prompts(prompt_config.prompt)
		return prompt_config
	else
		local mode = "split"
		if vim.bo.ft == "sia" then
			mode = "chat"
		elseif
			config.options.default.mode == "insert"
			or (config.options.default.mode == "auto" and opts.mode == "n")
			or opts.force_insert
		then
			mode = "insert"
		elseif
			config.options.default.mode == "diff" or (config.options.default.mode == "auto" and opts.mode == "v")
		then
			mode = "diff"
		end

		local mode_prompt = replace_named_prompts(vim.deepcopy(config.options.default.mode_prompt[mode]))
		table.insert(mode_prompt, { role = "user", content = table.concat(prompt, " ") })
		return {
			prompt = mode_prompt,
			prefix = config.options.default.prefix,
			suffix = config.options.default.suffix,
			temperature = config.options.default.temperature,
			model = config.options.default.model,
			mode = config.options.default.mode,
		}
	end
end

local function collect_user_prompts(prompts)
	local lines = {}
	for _, prompt in ipairs(prompts) do
		if prompt.role == "user" then
			for _, line in ipairs(vim.split(prompt.content, "\n", { plain = true, trimempty = false })) do
				table.insert(lines, line)
			end
		end
	end
	return lines
end

function sia.main(prompt, opts)
	-- Request
	local req_win = vim.api.nvim_get_current_win()
	local req_buf = vim.api.nvim_get_current_buf()
	local filetype = vim.bo.filetype

	local on_progress, on_complete, on_start
	local mode = prompt.mode or config.options.default.mode
	if opts.force_insert then
		mode = "insert"
	end

	if vim.api.nvim_buf_get_option(req_buf, "filetype") == "sia" then
		on_complete = function()
			vim.api.nvim_buf_set_lines(req_buf, -1, -1, false, { "", "" })
			local line_count = vim.api.nvim_buf_line_count(req_buf)
			vim.api.nvim_win_set_cursor(req_win, { line_count, 0 })
			vim.api.nvim_buf_del_keymap(req_buf, "n", "x")
		end
		on_progress = function(lines)
			if not vim.api.nvim_buf_is_valid(req_buf) then
				return
			end
			local row = vim.api.nvim_buf_get_lines(req_buf, 0, -1, false)
			local col = row[#row] or ""
			vim.api.nvim_buf_set_text(req_buf, #row - 1, #col, #row - 1, #col, lines)
			if vim.api.nvim_win_is_valid(req_win) then
				vim.api.nvim_win_set_cursor(req_win, { #row, #col })
			end
		end
		on_start = function(job)
			local line_count = vim.api.nvim_buf_line_count(req_buf)
			vim.api.nvim_buf_set_lines(req_buf, line_count - 1, -1, false, { "# User", "" })
			vim.api.nvim_buf_set_lines(req_buf, -1, -1, false, collect_user_prompts(prompt.prompt))
			vim.api.nvim_buf_set_lines(req_buf, -1, -1, false, { "", "", "# Assistant", "" })
			vim.api.nvim_buf_set_keymap(req_buf, "n", "x", "", {
				callback = function()
					vim.fn.jobstop(job)
				end,
			})
		end
	elseif mode == "insert" or (mode == "auto" and opts.mode == "n") then
		local current_row = opts.start_line
		if opts.mode == "v" and opts.force_insert == false then
			current_row = opts.end_line
		end

		local is_first = true
		on_progress = function(lines)
			if not vim.api.nvim_buf_is_valid(req_buf) then
				return
			end
			-- Join all changes to simplify undo
			if not is_first then
				vim.api.nvim_buf_call(req_buf, function()
					vim.cmd.undojoin()
				end)
			end
			is_first = false
			local current = vim.api.nvim_buf_get_lines(req_buf, current_row - 1, current_row, false)
			local col = #current[1]
			for i, line in ipairs(lines) do
				if line then
					if line == "" or line == "\n" then
						vim.api.nvim_buf_set_lines(req_buf, current_row, current_row, false, { "" })
						current_row = current_row + 1
						col = 0
					end
					vim.api.nvim_buf_set_text(req_buf, current_row - 1, col, current_row - 1, col, { line })
					col = col + #line
				end
			end
			if vim.api.nvim_win_is_valid(req_win) then
				if prompt.cursor == nil or prompt.cursor == "follow" then
					current = vim.api.nvim_buf_get_lines(req_buf, current_row - 1, current_row, false)
					vim.api.nvim_win_set_cursor(req_win, { current_row, #current[1] })
				end
			end
		end

		on_start = function(job)
			if prompt.insert and prompt.insert == "below" then
				vim.api.nvim_buf_set_lines(req_buf, current_row, current_row, false, { "" })
				current_row = current_row + 1
				col = 0
			end
			vim.api.nvim_buf_set_keymap(req_buf, "n", "x", "", {
				callback = function()
					vim.fn.jobstop(job)
				end,
			})
		end
		on_complete = function()
			vim.api.nvim_buf_del_keymap(req_buf, "n", "x")
			if prompt.cursor and prompt.cursor == "start" then
				vim.api.nvim_win_set_cursor(req_win, { opts.start_line, 0 })
			end
		end
	elseif mode == "diff" or (mode == "auto" and opts.mode == "v") then
		vim.cmd("vsplit")
		local res_win = vim.api.nvim_get_current_win()
		local res_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(res_win, res_buf)
		vim.api.nvim_buf_set_option(res_buf, "filetype", filetype)

		for _, wo in pairs(config.options.wo) do
			vim.api.nvim_win_set_option(res_win, wo, vim.api.nvim_win_get_option(req_win, wo))
		end

		-- Partition request buffer
		local before_context = vim.api.nvim_buf_get_lines(req_buf, 0, opts.start_line - 1, true)
		local after_context = vim.api.nvim_buf_get_lines(req_buf, opts.end_line, -1, true)

		-- Add line before the response
		vim.api.nvim_buf_set_lines(res_buf, 0, 0, true, before_context)
		vim.api.nvim_win_set_cursor(res_win, { opts.start_line, 0 })

		on_complete = function()
			-- Add line after the response
			vim.api.nvim_buf_set_lines(res_buf, -1, -1, true, after_context)

			-- Calculate diff
			vim.api.nvim_set_current_win(res_win)
			vim.cmd("diffthis")
			vim.api.nvim_set_current_win(req_win)
			vim.cmd("diffthis")

			vim.api.nvim_buf_del_keymap(res_buf, "n", "x")
		end
		on_progress = function(lines)
			if not vim.api.nvim_buf_is_valid(res_buf) then
				return
			end
			local row = vim.api.nvim_buf_get_lines(res_buf, 0, -1, false)
			local col = row[#row] or ""
			vim.api.nvim_buf_set_text(res_buf, #row - 1, #col, #row - 1, #col, lines)

			if vim.api.nvim_win_is_valid(res_win) then
				vim.api.nvim_win_set_cursor(res_win, { #row, #col })
			end
		end
		on_start = function(job)
			vim.api.nvim_buf_set_keymap(res_buf, "n", "x", "", {
				callback = function()
					vim.fn.jobstop(job)
				end,
			})
		end
	elseif mode == "split" then
		vim.cmd(prompt.split_cmd or config.options.default.split.cmd or "vsplit")
		local res_win = vim.api.nvim_get_current_win()
		local res_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(res_win, res_buf)
		vim.api.nvim_buf_set_option(res_buf, "filetype", "sia")
		vim.api.nvim_buf_set_option(res_buf, "syntax", "markdown")
		vim.api.nvim_buf_set_option(res_buf, "buftype", "nofile")

		local split_wo = prompt.wo or config.options.default.split.wo
		if split_wo then
			for key, value in pairs(split_wo) do
				vim.api.nvim_win_set_option(res_win, key, value)
			end
		end

		on_complete = function()
			if not vim.api.nvim_buf_is_valid(res_buf) then
				return
			end
			vim.api.nvim_buf_set_lines(res_buf, -1, -1, false, { "", "" })
			local line_count = vim.api.nvim_buf_line_count(res_buf)

			if vim.api.nvim_win_is_valid(res_win) then
				vim.api.nvim_win_set_cursor(res_win, { line_count, 0 })
			end
			vim.api.nvim_buf_del_keymap(res_buf, "n", "x")
		end
		on_progress = function(lines)
			local row = vim.api.nvim_buf_get_lines(res_buf, 0, -1, false)
			local col = row[#row] or ""
			vim.api.nvim_buf_set_text(res_buf, #row - 1, #col, #row - 1, #col, lines)
			if vim.api.nvim_win_is_valid(res_win) then
				vim.api.nvim_win_set_cursor(res_win, { #row, #col })
			end
		end
		on_start = function(job)
			local line_count = vim.api.nvim_buf_line_count(res_buf)
			vim.api.nvim_buf_set_lines(res_buf, line_count - 1, line_count, false, { "# User", "" })
			vim.api.nvim_buf_set_lines(res_buf, -1, -1, false, collect_user_prompts(prompt.prompt))
			vim.api.nvim_buf_set_lines(res_buf, -1, -1, false, { "", "# Assistant", "" })
			vim.api.nvim_buf_set_keymap(res_buf, "n", "x", "", {
				callback = function()
					vim.fn.jobstop(job)
				end,
			})
		end
	else
		vim.notify("invalid mode")
		return
	end

	local context, context_suffix
	if opts.mode == "v" then
		context = table.concat(vim.api.nvim_buf_get_lines(req_buf, opts.start_line - 1, opts.end_line, true), "\n")
	else
		local start_line
		if prompt.prefix and prompt.prefix ~= false then
			start_line = math.max(0, opts.start_line - prompt.prefix)
		else
			start_line = opts.start_line - (config.options.default.prefix or 1)
		end
		if prompt.prefix ~= false then
			context = table.concat(vim.api.nvim_buf_get_lines(req_buf, start_line, opts.start_line, true), "\n")
		else
			context = ""
		end

		local suffix = prompt.suffix or config.options.suffix
		if suffix and suffix > 0 then
			local line_count = vim.api.nvim_buf_line_count(req_buf)
			local end_line = math.min(line_count, opts.end_line + prompt.suffix)
			context_suffix = table.concat(vim.api.nvim_buf_get_lines(req_buf, opts.end_line - 1, end_line, true), "\n")
		else
			context_suffix = ""
		end
	end

	local ft = vim.api.nvim_buf_get_option(req_buf, "filetype")
	local replacement = {
		filetype = ft,
		filepath = vim.api.nvim_buf_get_name(req_buf),
		context = context,
		context_suffix = context_suffix,
		buffer = table.concat(vim.api.nvim_buf_get_lines(req_buf, 0, -1, true), "\n"),
	}

	local steps_to_remove = {}
	for i, step in ipairs(prompt.prompt) do
		if type(step.content) == "function" then
			step.content = step.content(ft)
		end
		step.content = step.content:gsub("{{(.-)}}", function(key)
			return replacement[key] or key
		end)
		if step.content == "" then
			table.insert(steps_to_remove, i)
		end
	end

	for _, step in ipairs(steps_to_remove) do
		table.remove(prompt.prompt, step)
	end
	require("sia.assistant").query(prompt, on_start, on_progress, on_complete)
end

return sia
