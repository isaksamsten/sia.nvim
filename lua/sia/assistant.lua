local M = {}

local ERROR_API_KEY_MISSING = -100
--- @class sia.Usage
--- @field total integer?
--- @field prompt integer?
--- @field completion integer?
--- @field total_time number

--- @class sia.ProviderOpts
--- @field on_stdout (fun(job:number, response: string[], _:any?):nil)
--- @field on_exit (fun(_: any, code:number, _:any?):nil)
--- @field stream boolean?

--- Call the provider defined in the query.
--- @param query sia.Query
--- @param opts sia.ProviderOpts
--- @return integer? jobid
local function call_provider(query, opts)
  local config = require("sia.config")
  local model
  local provider
  if query.model == nil or type(query.model) == "string" then
    model = config.options.models[query.model or config.get_default_model()]
    if not model then
      model = config.options.models[config.options.defaults.model]
      vim.notif("missing model, using default fallback")
    end
    provider = config.options.providers[model[1]]
  else
    model =
      { nil, query.model.name, temperature = query.model.temperature, function_calling = query.model.function_calling }
    provider = query.model.provider
  end

  local prompt = query.prompt
  if provider.format_messages then
    provider.format_messages(model[2], prompt)
  end

  --- @type { model: string, temperature: number, messages: sia.Prompt[], stream: boolean?, stream_options: {include_usage: boolean}?, max_tokens: integer?}
  local data = {
    model = model[2],
    messages = prompt,
    tools = query.tools,
  }

  if not config.options.defaults.tools.enable or model.function_calling == false then
    data.tools = nil
  end

  if not model.reasoning_effort then
    data.temperature = query.temperature or config.options.defaults.temperature
  end

  if model.temperature then
    data.temperature = model.temperature
  end

  if model.max_tokens then
    data.max_tokens = model.max_tokens
  end

  if model.n then
    data.n = model.n
  end

  if opts.stream then
    data.stream = true
    data.stream_options = { include_usage = true }
  end

  local api_key = provider.api_key()
  if api_key == nil then
    vim.notify("Sia: API key is not set for " .. model[1])
    opts.on_exit(nil, ERROR_API_KEY_MISSING, nil)
    return nil
  end

  local args = {
    "curl",
    "--silent",
    "--no-buffer",
    "--header",
    string.format("Authorization: Bearer %s", api_key),
    "--header",
    "content-type: application/json",
  }
  if string.find(provider.base_url, "githubcopilot") ~= nil then
    table.insert(args, "--header")
    table.insert(args, "Copilot-Integration-Id: vscode-chat")
    table.insert(args, "--header")
    table.insert(
      args,
      string.format("editor-version: Neovim/%s.%s.%s", vim.version().major, vim.version().minor, vim.version().patch)
    )
    table.insert(args, "--header")
    local initiator = "user"
    local last = query.prompt[#query.prompt]
    if last and last.role == "tool" then
      initiator = "agent"
    end
    table.insert(args, "X-Initiator: " .. initiator)
  end

  table.insert(args, "--url")
  table.insert(args, provider.base_url)
  table.insert(args, "--data-binary")

  local tmpfile = vim.fn.tempname()
  local ok = vim.fn.writefile({ vim.json.encode(data) }, tmpfile)
  if ok ~= 0 then
    error("Failed to write request to temp file")
  end
  table.insert(args, "@" .. tmpfile)
  return vim.fn.jobstart(args, {
    clear_env = true,
    on_stderr = function(_, a, _) end,
    on_stdout = opts.on_stdout,
    on_exit = opts.on_exit,
  })
end

local function extract_error(json)
  if json.error then
    return json.error
  end

  if vim.islist(json) then
    for _, part in ipairs(json) do
      if part.error then
        return part.error
      end
    end
  end
  return nil
end

--- @param strategy sia.Strategy
function M.execute_strategy(strategy)
  if strategy.is_busy then
    return
  end

  strategy.is_busy = true
  local start_time = vim.uv.hrtime()

  local function execute_round(is_initial)
    local timer
    if is_initial then
      if not strategy:on_init() then
        strategy:on_error()
        return
      end
      vim.api.nvim_exec_autocmds("User", {
        pattern = "SiaInit",
        --- @diagnostic disable-next-line: undefined-field
        data = { buf = strategy.buf },
      })
    else
      strategy:on_continue()
    end

    local query = strategy:get_query()
    local first_on_stdout = true
    local incomplete = nil
    local error_initialize = false
    --- @type sia.Usage
    local usage

    local job = call_provider(query, {
      on_stdout = function(job_id, responses, _)
        if first_on_stdout then
          first_on_stdout = false
          local response = table.concat(responses, " ")
          local status, json = pcall(vim.json.decode, response, { luanil = { object = true } })
          if status then
            local m_err = extract_error(json)
            if m_err then
              vim.api.nvim_exec_autocmds("User", {
                pattern = "SiaError",
                data = m_err,
              })
              error_initialize = true
              strategy.is_busy = false
              strategy:on_error()
              vim.fn.jobstop(job_id)
            end
          end
          if not error_initialize then
            if not strategy:on_start() then
              vim.fn.jobstop(job_id)
            end
            vim.api.nvim_exec_autocmds("User", {
              pattern = "SiaStart",
              --- @diagnostic disable-next-line: undefined-field
              data = { buf = strategy.buf, job = job_id },
            })
          end
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
                  usage = {
                    total = obj.usage.total_tokens or nil,
                    prompt = obj.usage.prompt_tokens or nil,
                    completion = obj.usage.completion_tokens or nil,
                    total_time = 0,
                  }
                end
                if obj.choices and #obj.choices > 0 then
                  local delta = obj.choices[1].delta
                  if delta then
                    if delta.reasoning and delta.reasoning ~= "" then
                      if not strategy:on_reasoning(delta.reasoning) then
                        vim.fn.jobstop(job_id)
                      end
                    end
                    if delta.content and delta.content ~= "" then
                      if not strategy:on_progress(delta.content) then
                        vim.fn.jobstop(job_id)
                      end
                    end
                    if delta.tool_calls and delta.tool_calls ~= "" then
                      if not strategy:on_tool_call(delta.tool_calls) then
                        vim.fn.jobstop(job_id)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end,
      on_exit = function(jobid, code, _)
        if timer then
          timer:stop()
          timer:close()
        end
        if error_initialize then
          return
        end

        if code == ERROR_API_KEY_MISSING or code == 143 or code == 137 then
          if code == 143 or code == 137 then
            strategy:on_cancelled()
          else
            strategy:on_error()
          end
          strategy.is_busy = false
          return
        end

        local finish = function()
          strategy.is_busy = false
          vim.api.nvim_exec_autocmds("User", {
            pattern = "SiaComplete",
            --- @diagnostic disable-next-line: undefined-field
            data = { buf = strategy.buf, job = jobid, usage = usage },
          })
        end

        local continue_execution = function()
          if strategy.cancellable.is_cancelled then
            strategy:on_cancelled()
            finish()
          else
            execute_round(false)
          end
        end

        if start_time then
          local total_time = (vim.uv.hrtime() - start_time) / 1000000 / 1000
          if usage then
            usage.total_time = total_time
          else
            usage = { total_time = total_time }
          end
        end

        strategy:on_complete({
          continue_execution = continue_execution,
          finish = finish,
          usage = usage,
        })
      end,
      stream = true,
    })
    timer = vim.uv.new_timer()
    timer:start(
      0,
      100,
      vim.schedule_wrap(function()
        if strategy.cancellable.is_cancelled then
          if job then
            vim.fn.jobstop(job)
          end
        end
      end)
    )
  end

  execute_round(true)
end

--- @param query sia.Query
--- @param callback fun(s:string?):nil
function M.execute_query(query, callback)
  local response = ""
  call_provider(query, {
    on_stdout = function(_, data, _)
      if data ~= nil then
        response = response .. table.concat(data, " ")
      end
    end,
    on_exit = function()
      if response ~= "" then
        local ok, json = pcall(vim.json.decode, response, { luanil = { object = true } })
        if ok then
          if json and json.choices and #json.choices > 0 then
            callback(json.choices[1].message.content)
          end
        end
      end
    end,
    stream = false,
  })
end

return M
