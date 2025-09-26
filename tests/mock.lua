local assistant = require("sia.assistant")
local M = {}
M.old_jobstart = vim.fn.jobstart

function M.mock_fn_jobstart(data)
  vim.fn.jobstart = function(_, job_opts)
    for _, datum in ipairs(data) do
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

function M.unmock_assistant()
  vim.fn.jobstart = M.old_jobstart
end

return M
