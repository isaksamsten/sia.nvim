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

-- Define a position tracker object
local BufAppend = {}
BufAppend.__index = BufAppend

-- Constructor for PositionTracker
function BufAppend:new(bufnr, line, col)
	local obj = {
		bufnr = bufnr, -- Buffer number
		line = line or 0, -- Start line
		col = col or 0, -- Start column
	}
	setmetatable(obj, self)
	return obj
end

-- Method to advance the column position
function BufAppend:advance(substring)
	self.col = self.col + #substring
end

-- Method to handle newline and reset column position
function BufAppend:newline()
	self.line = self.line + 1
	self.col = 0
end

-- Method to append content to the buffer
function BufAppend:append_to_buffer(content)
	local index = 1
	while index <= #content do
		local newline = content:find("\n", index) or (#content + 1)
		local substring = content:sub(index, newline - 1)

		if #substring > 0 then
			vim.api.nvim_buf_set_text(self.bufnr, self.line, self.col, self.line, self.col, { substring })
			self:advance(substring)
		end

		if newline <= #content then
			vim.api.nvim_buf_set_lines(self.bufnr, self.line + 1, self.line + 1, false, { "" })
			self:newline()
		end

		index = newline + 1
	end
end

-- Usage example:
local bufnr = vim.api.nvim_create_buf(false, true) -- Create a new buffer
local tracker = BufAppend:new(bufnr, 0, 0) -- Initialize tracker at line 0, col 0
tracker:append_to_buffer("Hello\nWorld") -- Use the instance method to append content

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
		local mode_prompt = "split"
		if vim.bo.ft == "sia" then
			mode_prompt = "chat"
		elseif
			config.options.default.mode == "insert"
			or (config.options.default.mode == "auto" and opts.mode == "n")
			or opts.force_insert
		then
			mode_prompt = "insert"
		elseif
			config.options.default.mode == "diff" or (config.options.default.mode == "auto" and opts.mode == "v")
		then
			mode_prompt = "diff"
		end

		mode_prompt = replace_named_prompts(vim.deepcopy(config.options.default.mode_prompt[mode_prompt]))
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

local function chat_strategy(res_buf, winnr, prompt)
	local buf_append = nil
	return {
		on_start = function(job)
			vim.api.nvim_buf_set_keymap(res_buf, "n", "x", "", {
				callback = function()
					vim.fn.jobstop(job)
				end,
			})
		end,
		on_progress = function(content)
			if buf_append == nil then
				local line_count = vim.api.nvim_buf_line_count(res_buf)
				vim.api.nvim_buf_set_lines(res_buf, line_count - 1, line_count, false, { "# User", "" })
				vim.api.nvim_buf_set_lines(res_buf, -1, -1, false, collect_user_prompts(prompt))
				vim.api.nvim_buf_set_lines(res_buf, -1, -1, false, { "", "# Assistant", "" })
				line_count = vim.api.nvim_buf_line_count(res_buf)
				buf_append = BufAppend:new(res_buf, line_count - 1, 0)
			end
			buf_append:append_to_buffer(content)
			if vim.api.nvim_win_is_valid(winnr) then
				vim.api.nvim_win_set_cursor(winnr, { buf_append.line, buf_append.col })
			end
		end,
		on_complete = function()
			if not vim.api.nvim_buf_is_valid(res_buf) then
				return
			end
			vim.api.nvim_buf_set_lines(res_buf, -1, -1, false, { "", "" })
			local line_count = vim.api.nvim_buf_line_count(res_buf)

			if vim.api.nvim_win_is_valid(winnr) then
				vim.api.nvim_win_set_cursor(winnr, { line_count, 0 })
			end
			vim.api.nvim_buf_del_keymap(res_buf, "n", "x")
		end,
	}
end

function sia.main(prompt, opts)
	-- Request
	local req_win = vim.api.nvim_get_current_win()
	local req_buf = vim.api.nvim_get_current_buf()
	local filetype = vim.bo.filetype

	if prompt.context then
		local start_line, end_line = prompt.context(req_buf, opts)
		if start_line == nil or end_line == nil then
			vim.notify("Couldn't capture context")
			return
		end
		opts.start_line = start_line
		opts.end_line = end_line
	end

	local on_progress, on_complete, on_start
	local mode = prompt.mode or config.options.default.mode
	if opts.force_insert then
		mode = "insert"
	end

	if vim.api.nvim_buf_get_option(req_buf, "filetype") == "sia" then
		local strategy = chat_strategy(req_buf, req_win, prompt.prompt)
		on_start = strategy.on_start
		on_progress = strategy.on_progress
		on_complete = strategy.on_complete
	elseif mode == "insert" or (mode == "auto" and opts.mode == "n") then
		local current_row = opts.start_line
		if opts.mode == "v" and opts.force_insert == false then
			current_row = opts.end_line
		end

		local is_first = true
		local buf_append = nil
		on_progress = function(content)
			if not vim.api.nvim_buf_is_valid(req_buf) then
				return
			end
			-- Join all changes to simplify undo
			if not is_first then
				vim.api.nvim_buf_call(req_buf, function()
					vim.cmd.undojoin()
				end)
			else
				buf_append = BufAppend:new(req_buf, current_row - 1, 0)
			end
			is_first = false

			if buf_append ~= nil then
				buf_append:append_to_buffer(content)
			end
			if vim.api.nvim_win_is_valid(req_win) then
				if prompt.cursor == nil or prompt.cursor == "follow" then
					vim.api.nvim_win_set_cursor(req_win, { buf_append.line, buf_append.col })
				end
			end
		end

		on_start = function(job)
			local placement = prompt.insert
			if type(placement) == "function" then
				placement = placement(req_buf)
			end

			if placement and placement == "below" then
				vim.api.nvim_buf_set_lines(req_buf, current_row, current_row, false, { "" })
				current_row = current_row + 1
				col = 0
			elseif placement and placement == "above" then
				vim.api.nvim_buf_set_lines(req_buf, current_row - 1, current_row - 1, false, { "" })
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

		for _, wo in pairs(config.options.default.diff.wo or {}) do
			vim.api.nvim_win_set_option(res_win, wo, vim.api.nvim_win_get_option(req_win, wo))
		end

		-- Partition request buffer
		local before_context = vim.api.nvim_buf_get_lines(req_buf, 0, opts.start_line - 1, true)
		local after_context = vim.api.nvim_buf_get_lines(req_buf, opts.end_line, -1, true)

		-- Add line before the response
		vim.api.nvim_buf_set_lines(res_buf, 0, 0, true, before_context)
		vim.api.nvim_win_set_cursor(res_win, { opts.start_line, 0 })

		local buf_append = BufAppend:new(res_buf, opts.start_line, 0)
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
		on_progress = function(content)
			if not vim.api.nvim_buf_is_valid(res_buf) then
				return
			end
			buf_append.append_to_buffer(content)

			if vim.api.nvim_win_is_valid(res_win) then
				vim.api.nvim_win_set_cursor(res_win, { buf_append.line, buf_append.col })
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

		local strategy = chat_strategy(res_buf, res_win, prompt.prompt)
		on_start = strategy.on_start
		on_complete = strategy.on_complete
		on_progress = strategy.on_progress
	else
		vim.notify("invalid mode")
		return
	end

	local context, context_suffix
	if opts.mode == "v" or opts.context ~= nil then
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
