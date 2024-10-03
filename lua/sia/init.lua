local config = require("sia.config")
local Conversation = require("sia.conversation").Conversation
local SplitStrategy = require("sia.strategy").SplitStrategy
local DiffStrategy = require("sia.strategy").DiffStrategy
local InsertStrategy = require("sia.strategy").InsertStrategy
local Message = require("sia.conversation").Message

local M = {}

function M.setup(options)
  config.setup(options)
  require("sia.mappings").setup()
  vim.treesitter.language.register("markdown", "sia")

  local augroup = vim.api.nvim_create_augroup("SiaGroup", { clear = true })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    pattern = "*",
    callback = function(args)
      if vim.bo[args.buf].filetype == "sia" then
        SplitStrategy.remove(args.buf)
      end
    end,
  })
  if config.options.report_usage == true then
    vim.api.nvim_create_autocmd("User", {
      group = augroup,
      pattern = "SiaUsageReport",
      callback = function(args)
        local data = args.data
        if data then
          vim.notify("Total tokens: " .. data.total_tokens)
        end
      end,
    })
  end
end

--- @param action sia.config.Action
--- @param opts sia.ActionArgument
function M.main(action, opts)
  if vim.api.nvim_buf_is_valid(opts.buf) and vim.api.nvim_buf_is_loaded(opts.buf) then
    local strategy
    if vim.bo[opts.buf].filetype == "sia" then
      strategy = SplitStrategy.by_buf(opts.buf)
      if strategy then
        strategy:extend(Message:new(action.instructions[#action.instructions], opts))
      end
    else
      local conversation = Conversation:new(action, opts)
      if conversation.mode == "diff" then
        strategy =
          DiffStrategy:new(conversation, vim.tbl_deep_extend("force", config.options.defaults.diff, action.diff or {}))
      elseif conversation.mode == "insert" then
        strategy = InsertStrategy:new(
          conversation,
          vim.tbl_deep_extend("force", config.options.defaults.insert, action.insert or {})
        )
      else
        strategy = SplitStrategy:new(
          conversation,
          vim.tbl_deep_extend("force", config.options.defaults.split, action.split or {})
        )
      end
    end

    if strategy then
      require("sia.assistant").execute_strategy(strategy)
    end
  end
end

return M
