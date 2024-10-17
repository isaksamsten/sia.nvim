local M = {}

--- @class sia.ProviderOpts
--- @field on_stdout (fun(job:number, response: string[], _:any?):nil)
--- @field on_exit (fun(_: any, code:number, _:any?):nil)
--- @field stream boolean?

--- Call the provider defined in the query.
--- @param query sia.Query
--- @param opts sia.ProviderOpts
local function call_provider(query, opts)
  local config = require("sia.config")
  local model = config.options.models[query.model or config.options.defaults.model]
  local provider = config.options.providers[model[1]]

  --- @type { model: string, temperature: number, messages: sia.Prompt[], stream: boolean?, stream_options: {include_usage: boolean}?}
  local data = {
    model = model[2],
    temperature = query.temperature or config.options.defaults.temperature,
    messages = query.prompt,
    tools = query.tools,
  }

  if opts.stream then
    data.stream = true
    data.stream_options = { include_usage = true }
  end

  local args = {
    "--silent",
    "--no-buffer",
    '--header "Authorization: Bearer $API_KEY"',
    '--header "content-type: application/json"',
  }
  if string.find(provider.base_url, "githubcopilot") ~= nil then
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

  table.insert(args, "--url " .. provider.base_url)
  table.insert(args, "--data " .. vim.fn.shellescape(vim.json.encode(data)))
  local command = "curl " .. table.concat(args, " ")

  vim.fn.jobstart(command, {
    clear_env = true,
    env = {
      API_KEY = provider.api_key(),
    },
    on_stdout = opts.on_stdout,
    on_exit = opts.on_exit,
  })
end

--- @param strategy sia.Strategy
function M.execute_strategy(strategy)
  local query = strategy:get_query()
  local first_on_stdout = true
  local incomplete = nil
  strategy:on_init()
  vim.api.nvim_exec_autocmds("User", {
    pattern = "SiaInit",
    --- @diagnostic disable-next-line: undefined-field
    data = { buf = strategy.buf },
  })
  call_provider(query, {
    on_stdout = function(job_id, responses, _)
      if first_on_stdout then
        strategy:on_start(job_id)
        first_on_stdout = false
        vim.api.nvim_exec_autocmds("User", {
          pattern = "SiaStart",
          --- @diagnostic disable-next-line: undefined-field
          data = { buf = strategy.buf },
        })

        local status, json = pcall(vim.json.decode, responses[1], { luanil = { object = true } })
        if status then
          if json.error then
            vim.api.nvim_exec_autocmds("User", {
              pattern = "SiaError",
              data = json.error,
            })
            strategy:on_progress(json.error.message)
          end
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
                vim.api.nvim_exec_autocmds("User", {
                  pattern = "SiaUsageReport",
                  data = obj.usage,
                })
              end
              if obj.choices and #obj.choices > 0 then
                local delta = obj.choices[1].delta
                if delta then
                  if delta.content then
                    strategy:on_progress(delta.content)
                    vim.api.nvim_exec_autocmds("User", {
                      pattern = "SiaProgress",
                      --- @diagnostic disable-next-line: undefined-field
                      data = { buf = strategy.buf, content = delta.content },
                    })
                  elseif delta.tool_calls then
                    strategy:on_tool_call(delta.tool_calls)
                  end
                end
              end
            end
          end
        end
      end
    end,
    on_exit = function(_, error_code, _)
      strategy:on_complete()
      vim.api.nvim_exec_autocmds("User", {
        pattern = "SiaComplete",
        --- @diagnostic disable-next-line: undefined-field
        data = { buf = strategy.buf, error_code = error_code },
      })
    end,
    stream = true,
  })
end

--- @param query sia.Query
--- @param callback fun(s:string):nil
function M.execute_query(query, callback)
  call_provider(query, {
    on_stdout = function(_, data, _)
      if data and data ~= nil then
        data = table.concat(data, " ")
        if data ~= "" then
          local ok, json = pcall(vim.json.decode, data, { luanil = { object = true } })
          if ok and json and json.choices and #json.choices > 0 then
            callback(json.choices[1].message.content)
          end
        end
      end
    end,
    on_exit = function() end,
    stream = false,
  })
end

return M
