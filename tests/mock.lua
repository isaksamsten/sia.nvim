local assistant = require("sia.assistant")
local M = {}
M.old_jobstart = vim.fn.jobstart

function M.mock_fn_jobstart(data)
  vim.fn.jobstart = function(_, job_opts)
    -- Check if this is an error response
    if data.error then
      job_opts.on_stdout(1, { vim.json.encode(data) }, 10)
      job_opts.on_exit(1, 0, nil)
      return 1
    end

    for _, datum in ipairs(data) do
      -- Neovim splits by newlines, so each element is a line without trailing \n
      job_opts.on_stdout(1, { "data: " .. vim.json.encode(datum) }, 10)
    end
    job_opts.on_stdout(1, {
      "data: " .. vim.json.encode({ choices = { { delta = {} } }, usage = { total_tokens = 12 } }),
    }, 10)

    job_opts.on_stdout(1, { "data: [DONE]" }, nil)
    job_opts.on_exit(1, 0, nil)
    return 1
  end
end

--- Custom mock that takes a function to control the exact sequence of events
--- @param fn fun(args: string[], job_opts: table): integer
function M.mock_fn_jobstart_custom(fn)
  vim.fn.jobstart = fn
end

function M.unmock_assistant()
  vim.fn.jobstart = M.old_jobstart
end

return M
