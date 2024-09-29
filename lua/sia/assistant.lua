local config = require("sia.config")
local assistant = {}

local function sanitize_prompt(prompt)
  local out = {}
  for i, step in ipairs(prompt) do
    out[i] = { role = step.role, content = step.content }
  end
  return out
end

local function copilot_api_key()
  local token = nil
  local oauth = nil

  local function find_config()
    local config = vim.fn.expand("$XDG_CONFIG_HOME")
    if config and vim.fn.isdirectory(config) > 0 then
      return config
    elseif vim.fn.has("win32") > 0 then
      config = vim.fn.expand("~/AppData/Local")
      if vim.fn.isdirectory(config) > 0 then
        return config
      end
    else
      config = vim.fn.expand("~/.config")
      if vim.fn.isdirectory(config) > 0 then
        return config
      end
    end
  end

  local function get_oauth_token()
    if oauth then
      return oauth
    end
    local config_home = find_config()
    if not config_home then
      return nil
    end
    local apps = config_home .. "/github-copilot/apps.json"
    if vim.fn.filereadable(apps) == 1 then
      local data = vim.json.decode(table.concat(vim.fn.readfile(apps), " "))
      for key, value in pairs(data) do
        if string.find(key, "github.com") then
          return value.oauth_token
        end
      end
    end
    return nil
  end

  return function()
    if token and token.expires_at > os.time() then
      return token.token
    end

    oauth = get_oauth_token()
    if not oauth then
      vim.notify("Can't find Copilot auth token")
    end

    local cmd = table.concat({
      "curl",
      "--silent",
      '--header "Authorization: Bearer ' .. oauth .. '"',
      '--header "Content-Type: application/json"',
      '--header "Accept: application/json"',
      "https://api.github.com/copilot_internal/v2/token",
    }, " ")
    local response = vim.fn.system(cmd)
    local status, json = pcall(vim.json.decode, response)
    if status then
      token = json
      return token.token
    end
  end
end

local adapters = {
  openai = {
    base_url = "https://api.openai.com/v1/chat/completions",
    api_key = function()
      return os.getenv("OPENAI_API_KEY")
    end,
  },
  copilot = {
    base_url = "https://api.githubcopilot.com/chat/completions",
    api_key = copilot_api_key(),
  },
}

--- Encodes the given prompt into a JSON string.
---
--- @param prompt table: A table containing the details of the prompt.
--- @param stream boolean|nil: stream the response or not
--- @return string prompt A JSON-encoded string representing the prompt.
local function encode_request(prompt, model, opts)
  local data = {
    model = model,
    temperature = prompt.temperature or config.options.default.temperature,
    messages = sanitize_prompt(prompt.prompt),
  }
  if opts == nil or opts.stream == true then
    data.stream = true
    data.stream_options = { include_usage = true }
  end
  return vim.json.encode(data)
end

local function curl(adapter, request)
  local args = {
    "--silent",
    "--no-buffer",
    '--header "Authorization: Bearer ' .. adapter.api_key() .. '"',
    '--header "content-type: application/json"',
  }
  if string.find(adapter.base_url, "githubcopilot") ~= nil then
    table.insert(args, '--header "Copilot-Integration-Id: vscode-chat"')
    table.insert(
      args,
      string.format(
        '--header "editor-version: Neovim/%s.%s.%s"',
        vim.version().major,
        vim.version().minor,
        vim.version().patch
      )
    )
  end

  table.insert(args, "--url " .. adapter.base_url)
  table.insert(args, "--data " .. vim.fn.shellescape(request))
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

  local provider = config.options.models[prompt.model or config.options.default.model]
  local adapter = adapters[provider[1]]
  local model = provider[2]
  vim.fn.jobstart(curl(adapter, encode_request(prompt, model)), {
    clear_env = true,
    env = {
      API_KEY = adapter.api_key(),
    },
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
  local provider = config.options.models[config.options.default.model]
  local adapter = adapters[provider[1]]
  local model = provider[2]
  vim.fn.jobstart(curl(adapter, encode_request(prompt, model, { stream = false })), {
    clear_env = true,
    env = {
      API_KEY = adapter.api_key(),
    },
    on_stdout = on_stdout,
    on_exit = on_exit,
  })
end

return assistant
