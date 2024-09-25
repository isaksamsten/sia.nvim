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

--- Executes a query and handles its progress and completion through callbacks.
---
--- @param prompt table: The query prompt to be sent.
--- @param on_start function: Callback function to be executed when the query starts. Receives the job ID as an argument.
--- @param on_progress function: Callback function to be executed when there's progress in the query. Receives the content of the response as an argument.
--- @param on_complete function: Callback function to be executed when the query completes.
--- @return nil: This function does not return a value.
function assistant.query(prompt, on_start, on_progress, on_complete)
  local first_on_stdout = true
  local incomplete = nil
  local function on_stdout(job_id, responses, _)
    if first_on_stdout then
      on_start(job_id)
      first_on_stdout = false
      vim.api.nvim_exec_autocmds("User", {
        pattern = "SiaStart",
        data = prompt,
      })
    end

    for _, resp in pairs(responses) do
      if resp and resp ~= "" then
        if incomplete then
          resp = incomplete .. resp
          incomplete = nil
        end
        resp = string.match(resp, "^data: (.+)$")
        if resp and resp ~= "[DONE]" then
          local status, obj = pcall(vim.json.decode, resp, { luanil = { object = true } })
          if not status then
            incomplete = "data: " .. resp
          else
            if obj.usage then
              vim.api.nvim_exec_autocmds("User", {
                pattern = "SiaUsageReport",
                data = obj.usage,
              })
            end
            if obj.choices and #obj.choices > 0 then
              local delta = obj.choices[1].delta
              if delta and delta.content then
                on_progress(delta.content)
                vim.api.nvim_exec_autocmds("User", {
                  pattern = "SiaProgress",
                })
              end
            end
          end
        end
      end
    end
  end

  local function on_exit(_, error_code, _)
    on_complete()
    vim.api.nvim_exec_autocmds("User", {
      pattern = "SiaComplete",
      data = { prompt = prompt, error_code = error_code },
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
