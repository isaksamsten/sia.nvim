local config = require("sia.config")
local assistant = {}

local function encode(prompt)
	local json = vim.json.encode({
		model = prompt.model or config.options.default.model,
		temperature = prompt.temperature or config.options.default.temperature,
		stream = true,
		stream_options = {
			include_usage = true,
		},
		messages = prompt.prompt,
	})
	return json
end

local function command(req)
	local args = {
		"--silent",
		"--no-buffer",
		'--header "Authorization: Bearer $OPENAI_API_KEY"',
		'--header "content-type: application/json"',
		"--url https://api.openai.com/v1/chat/completions",
		"--data " .. vim.fn.shellescape(req),
	}
	return "curl " .. table.concat(args, " ")
end

--- @return table
local function decode_stream(data)
	local output = {}
	if data and data ~= "" then
		local data_mod = data:sub(7)
		local ok, json = pcall(vim.json.decode, data_mod, { luanil = { object = true } })
		if ok then
			if json.usage then
				output.usage = json.usage
			end

			if json.choices and #json.choices > 0 then
				local delta = json.choices[1].delta
				if delta.content and delta.content ~= "" then
					output.content = delta.content
				end
			end
		end
	end
	return output
end

function assistant.query(prompt, on_start, on_progress, on_complete)
	local first_on_stdout = true
	local function on_stdout(job_id, responses, _)
		if first_on_stdout then
			on_start(job_id)
			first_on_stdout = false
			vim.api.nvim_exec_autocmds("User", {
				pattern = "SiaStart",
				data = prompt,
			})
		end

		for _, response in pairs(responses) do
			local structured_response = decode_stream(response)
			if structured_response.content then
				on_progress(structured_response.content)
				vim.api.nvim_exec_autocmds("User", {
					pattern = "SiaProgress",
				})
			end

			if structured_response.usage then
				vim.api.nvim_exec_autocmds("User", {
					pattern = "SiaUsageReport",
					data = structured_response.usage,
				})
			end
		end
	end

	local function on_exit()
		on_complete()
		vim.api.nvim_exec_autocmds("User", {
			pattern = "SiaComplete",
			data = prompt,
		})
	end

	vim.fn.jobstart(command(encode(prompt)), {
		clear_env = true,
		env = { OPENAI_API_KEY = os.getenv(config.options.openai_api_key) },
		on_stdout = on_stdout,
		on_exit = on_exit,
	})
end

return assistant
