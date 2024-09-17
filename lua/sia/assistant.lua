local config = require("sia.config")
local assistant = {}

--- Encodes the given prompt into a JSON string.
---
--- @param prompt table: A table containing the details of the prompt.
--- @param stream boolean|nil: stream the response or not
--- @return string prompt A JSON-encoded string representing the prompt.
local function encode(prompt, stream)
	local data = {
		model = prompt.model or config.options.default.model,
		temperature = prompt.temperature or config.options.default.temperature,
		messages = prompt.prompt,
	}
	if stream == nil or stream == true then
		data.stream = true
		data.stream_options = { include_usage = true }
	end
	return vim.json.encode(data)
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
--- @param data string The JSON-encoded string to decode. It should be a non-empty string.
--- @return table response containing extracted information. The table may contain the
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
--- @param prompt table: The query prompt to be sent.
--- @param on_start function: Callback function to be executed when the query starts. Receives the job ID as an argument.
--- @param on_progress function: Callback function to be executed when there's progress in the query. Receives the content of the response as an argument.
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

function assistant.simple_query(query, on_content)
	local on_stdout = function(_, data, _)
		if data and data ~= nil then
			data = table.concat(data, " ")
			if data ~= "" then
				local ok, json = pcall(vim.json.decode, data, { luanil = { object = true } })
				if ok and json and json.choices and #json.choices > 0 then
					on_content(json.choices[1].message.content)
				end
			end
		end
	end
	local on_exit = function() end
	local prompt = { prompt = query }
	vim.fn.jobstart(command(encode(prompt, false)), {
		clear_env = true,
		env = { OPENAI_API_KEY = os.getenv(config.options.openai_api_key) },
		on_stdout = on_stdout,
		on_exit = on_exit,
	})
end

return assistant
