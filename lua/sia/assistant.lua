local config = require("sia.config")
local assistant = {}

--- Encodes the given prompt into a JSON string.
---
--- @param prompt table: A table containing the details of the prompt.
---  - model string: (Optional) The model to use. Defaults to the configured default model.
---  - temperature number: (Optional) The temperature setting. Defaults to the configured default temperature.
---  - prompt table: The messages to be included in the prompt.
--- @return string prompt A JSON-encoded string representing the prompt.
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

--- Decodes a JSON-encoded stream and extracts specific information.
---
--- @param data The JSON-encoded string to decode. It should be a non-empty string.
--- @return A table containing extracted information. The table may contain the
--- keys 'usage' and 'content' if they are present in the decoded JSON.
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
				if delta.content then
					output.content = delta.content
				end
			end
		end
	end
	return output
end

--- Executes a query and handles its progress and completion through callbacks.
---
--- @param prompt string: The query prompt to be sent.
--- @param on_start function: Callback function to be executed when the query starts. Receives the job ID as an argument.
--- @param on_progress: Callback function to be executed when there's progress in the query. Receives the content of the response as an argument.
--- @param on_complete function: Callback function to be executed when the query completes.
--- @return nil: This function does not return a value.
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
