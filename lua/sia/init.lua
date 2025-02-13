local config = require("sia.config")
local utils = require("sia.utils")
local Conversation = require("sia.conversation").Conversation
local SplitStrategy = require("sia.strategy").SplitStrategy
local DiffStrategy = require("sia.strategy").DiffStrategy
local InsertStrategy = require("sia.strategy").InsertStrategy
local HiddenStrategy = require("sia.strategy").HiddenStrategy

local M = {}

local highlight_groups = {
  SiaDiffDelete = { link = "DiffDelete" },
  SiaDiffDeleteHeader = { link = "DiffDelete" },
  SiaDiffChange = { link = "DiffChange" },
  SiaDiffChangeHeader = { link = "DiffChange" },
  SiaDiffDelimiter = { link = "Normal" },
}
local function set_highlight_groups()
  for group, attr in pairs(highlight_groups) do
    local existing = vim.api.nvim_get_hl(0, { name = group })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, group, attr)
    end
  end
end

function M.setup(options)
  config.setup(options)
  set_highlight_groups()
  require("sia.markers").setup()
  require("sia.mappings").setup()

  vim.api.nvim_create_user_command("SiaAccept", function()
    require("sia.markers").accept(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command("SiaReject", function()
    require("sia.markers").reject(vim.api.nvim_get_current_buf())
  end, {})

  vim.api.nvim_create_user_command("SiaFile", function(args)
    local split = SplitStrategy.by_buf()
    if #args.fargs == 0 then
      local files
      if split then
        files = split.files
      else
        files = utils.get_global_files()
      end
      print(table.concat(files, ", "))
    else
      if args.bang then
        if split then
          split.files = {}
        else
          utils.clear_global_files()
        end
      end
      local files = utils.glob_pattern_to_files(args.fargs)

      if split then
        split:add_files(files)
      else
        utils.add_global_files(files)
      end
    end
  end, { nargs = "*", bang = true, bar = true, complete = "file" })

  vim.api.nvim_create_user_command("SiaFileDelete", function(args)
    local split = SplitStrategy.by_buf()
    if split then
      split:remove_files(args.fargs)
    else
      utils.remove_global_files(args.fargs)
    end
  end, {
    nargs = "+",
    complete = function(arg_lead)
      local split = SplitStrategy.by_buf()
      local files
      if split then
        files = split.files
      else
        files = utils.get_global_files()
      end
      local matches = {}
      for _, file in ipairs(files) do
        if vim.fn.match(file, "^" .. vim.fn.escape(arg_lead, "\\")) >= 0 then
          table.insert(matches, file)
        end
      end
      return matches
    end,
  })

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

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "SiaError",
    callback = function(args)
      local data = args.data
      if data.message then
        vim.notify("Sia: " .. data.message, vim.log.levels.WARN)
      else
        vim.notify("Sia: unknown error", vim.log.levels.WARN)
      end
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    pattern = "*",
    callback = function(args)
      set_highlight_groups()
    end,
  })

  if config.options.report_usage == true then
    vim.api.nvim_create_autocmd("User", {
      group = augroup,
      pattern = "SiaUsageReport",
      callback = function(args)
        local data = args.data
        if data and data.usage then
          local usage = data.usage
          local model = data.model
          if not (usage.completion_tokens or usage.prompt_tokens) and usage.total_tokens then
            local prompt = { { "" .. usage.total_tokens, "NonText" } }
            if model then
              table.insert(prompt, 1, { model.name, "Comment" })
            end
            vim.api.nvim_echo(prompt, false, {})
          elseif usage.completion_tokens and usage.prompt_tokens then
            local prompt = {
              { " " .. usage.prompt_tokens, "NonText" },
              { "/", "NonText" },
              { "" .. usage.completion_tokens, "NonText" },
            }
            if model then
              if model.cost then
                local total_cost = usage.completion_tokens * model.cost.completion_tokens
                  + usage.prompt_tokens * model.cost.prompt_tokens
                if total_cost < 0.1 then
                  total_cost = "<0.1"
                else
                  total_cost = string.format("%.2f", total_cost)
                end

                table.insert(prompt, {
                  string.format(" ($%s)", total_cost),
                  "NonText",
                })
              end
              table.insert(prompt, 1, { model.name, "Comment" })
            end
            vim.api.nvim_echo(prompt, false, {})
          end
        end
      end,
    })
  end
end

--- @param action sia.config.Action
--- @param opts sia.ActionArgument
--- @param model string?
function M.main(action, opts, model)
  if vim.api.nvim_buf_is_valid(opts.buf) and vim.api.nvim_buf_is_loaded(opts.buf) then
    local strategy
    if vim.bo[opts.buf].filetype == "sia" then
      strategy = SplitStrategy.by_buf(opts.buf)
      if strategy then
        local last_instruction = action.instructions[#action.instructions] --[[@as sia.config.Instruction ]]
        strategy:add_instruction(last_instruction, opts)

        -- The user might have explicitly changed the model with -m
        if model then
          strategy.conversation.model = model
        end
      end
    else
      if model then
        action.model = model
      end
      local conversation = Conversation:new(action, opts)
      if conversation.mode == "diff" then
        local options = vim.tbl_deep_extend("force", config.options.defaults.diff, action.diff or {})
        strategy = DiffStrategy:new(conversation, options)
      elseif conversation.mode == "insert" then
        local options = vim.tbl_deep_extend("force", config.options.defaults.insert, action.insert or {})
        strategy = InsertStrategy:new(conversation, options)
      elseif conversation.mode == "hidden" then
        local options = vim.tbl_deep_extend("force", config.options.defaults.hidden, action.hidden or {})
        if not options.callback then
          vim.notify("Hidden strategy requires a callback function", vim.log.levels.ERROR)
          return
        end
        strategy = HiddenStrategy:new(conversation, options)
      else
        local options = vim.tbl_deep_extend("force", config.options.defaults.split, action.split or {})
        strategy = SplitStrategy:new(conversation, options)
      end
    end

    --- @cast strategy sia.Strategy
    require("sia.assistant").execute_strategy(strategy)
  end
end

return M
