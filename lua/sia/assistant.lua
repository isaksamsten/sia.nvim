local M = {}

local ERROR_API_KEY_MISSING = -100
--- @class sia.Usage
--- @field total integer?
--- @field prompt integer?
--- @field completion integer?
--- @field total_time number

--- @class sia.ProviderOpts
--- @field on_stdout (fun(job:number, response: string[], _:any?):nil)
--- @field on_exit (fun( _: any, code:number, _:any?):nil)
--- @field base_url string
--- @field api_key string?
--- @field extra_args string[]?
--- @field stream boolean?

--- Call the provider defined in the query.
--- @param data table
--- @param opts sia.ProviderOpts
--- @return integer? jobid
local function call_provider(data, opts)
  local api_key = opts.api_key
  if api_key == nil then
    vim.notify("Sia: API key is not set for " .. opts.base_url)
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

  for _, header in ipairs(opts.extra_args or {}) do
    table.insert(args, header)
  end

  table.insert(args, "--url")
  table.insert(args, opts.base_url)
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
  local config = require("sia.config")

  strategy.is_busy = true
  local start_time = vim.uv.hrtime()

  local function execute_round(is_initial)
    local timer
    if is_initial then
      if not strategy:on_request_start() then
        strategy.is_busy = false
        strategy:on_error()
        return
      end
      vim.api.nvim_exec_autocmds("User", {
        pattern = "SiaInit",
        --- @diagnostic disable-next-line: undefined-field
        data = { buf = strategy.buf },
      })
    end
    strategy:on_round_started()

    local provider

    local model =
      config.options.models[strategy.conversation.model or config.get_default_model()]
    if not model then
      model = config.options.models[config.options.defaults.model]
    end
    provider = config.options.providers[model[1]]

    local data = {
      model = model[2],
      stream = true,
    }

    local messages = strategy.conversation:prepare_messages()
    provider.prepare_tools(data, strategy.conversation.tools)
    provider.prepare_messages(data, model[2], messages)

    if provider.prepare_parameters then
      provider.prepare_parameters(data, model)
    end

    local extra_args = provider.get_headers and provider.get_headers(messages)
    local first_on_stdout = true
    local incomplete = nil
    local error_initialize = false
    --- @type sia.Usage?
    local usage

    local job = call_provider(data, {
      base_url = provider.base_url,
      api_key = provider.api_key(),
      extra_args = extra_args,
      on_stdout = function(job_id, responses, _)
        if first_on_stdout then
          first_on_stdout = false
          local response = table.concat(responses, " ")
          local status, json = pcall(vim.json.decode, response, {
            luanil = { object = true },
          })
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
            if not strategy:on_stream_started() then
              strategy.is_busy = false
              strategy:on_error()
              vim.fn.jobstop(job_id)
              return
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
              local status, obj = pcall(vim.json.decode, resp, {
                luanil = { object = true },
              })
              if not status then
                incomplete = "data: " .. resp
              else
                if provider.process_usage then
                  usage = provider.process_usage(obj)
                end
                if provider.process_stream_chunk(strategy, obj) then
                  vim.fn.jobpid(job_id)
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

        strategy:on_completed({
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

--- @param messages sia.Message[]
--- @param opts {callback:fun(s:string?), model:string}
function M.execute_query(messages, opts)
  local config = require("sia.config")
  local response = ""
  local model = config.options.models[opts.model or config.get_default_model()]
  if not model then
    model = config.options.models[config.options.defaults.model]
  end
  local provider = config.options.providers[model[1]]

  local data = {
    model = model[2],
  }
  provider.prepare_messages(data, model[2], messages)
  if provider.prepare_parameters then
    provider.prepare_parameters(data, model)
  end
  call_provider(data, {
    base_url = provider.base_url,
    api_key = provider.api_key(),
    on_stdout = function(_, resp, _)
      if data ~= nil then
        response = response .. table.concat(resp, " ")
      end
    end,
    on_exit = function()
      if response ~= "" then
        local ok, json = pcall(vim.json.decode, response, {
          luanil = { object = true },
        })

        if ok and json then
          opts.callback(provider.process_response(json))
        else
          opts.callback(nil)
        end
      end
    end,
    stream = false,
  })
end

return M
