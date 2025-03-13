local config = require("sia.config")
local utils = require("sia.utils")
local Conversation = require("sia.conversation").Conversation
local SplitStrategy = require("sia.strategy").SplitStrategy
local DiffStrategy = require("sia.strategy").DiffStrategy
local InsertStrategy = require("sia.strategy").InsertStrategy
local HiddenStrategy = require("sia.strategy").HiddenStrategy

local M = {}

local highlight_groups = {
  SiaSplitResponse = { link = "CursorLine" },
  SiaInsert = { link = "DiffAdd" },
  SiaReplace = { link = "DiffChange" },
  SiaProgress = { link = "NonText" },
  SiaModel = { link = "NonText" },
  SiaAssistant = { link = "DiffAdd" },
  SiaUser = { link = "DiffChange" },
}

local function set_highlight_groups()
  for group, attr in pairs(highlight_groups) do
    local existing = vim.api.nvim_get_hl(0, { name = group })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, group, attr)
    end
  end
end

function M.replace(opts)
  opts = opts or {}
  local split = SplitStrategy.by_buf()
  if split then
    local line = vim.api.nvim_win_get_cursor(0)[1]
    local block = split:find_block(line)
    if block then
      vim.schedule(function()
        require("sia.blocks").replace_all_blocks(split.block_action, { block }, { apply_marker = opts.apply_marker })
      end)
    end
  end
end

function M.replace_all(opts)
  opts = opts or {}
  local split = SplitStrategy.by_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if split then
    vim.schedule(function()
      require("sia.blocks").replace_all_blocks(
        split.block_action,
        split:find_all_blocks(line),
        { apply_marker = opts.apply_marker }
      )
    end)
  end
end

function M.insert(opts)
  local split = SplitStrategy.by_buf()
  if split then
    local padding = 0
    if opts.above then
      padding = 1
    end

    local line = vim.api.nvim_win_get_cursor(0)[1]
    local block = split:find_block(line)
    if block then
      vim.schedule(function()
        require("sia.blocks").insert_block(split.block_action, block, config.options.defaults.replace, padding)
      end)
    end
  end
end

function M.remove_message()
  local split = SplitStrategy.by_buf()
  if split then
    local contexts, mappings = split.conversation:get_message_mappings()
    if #contexts == 0 then
      vim.notify("Sia: No messages in current conversation.")
      return
    end
    vim.ui.select(contexts, {
      prompt = "Delete context",
      --- @param idx integer?
    }, function(_, idx)
      if idx then
        split.conversation:remove_instruction(mappings[idx])
      end
    end)
  end
end

--- @param opts table?
function M.show_messages(opts)
  opts = opts or {}
  local split = SplitStrategy.by_buf()
  if split then
    local contexts, mappings = split.conversation:get_messages({ mapping = true })
    if #contexts == 0 then
      vim.notify("Sia: No messages in the current conversation.")
      return
    end
    vim.ui.select(contexts, {
      prompt = "Show message",
      --- @param message sia.Message
      format_item = function(message)
        return message:get_description()
      end,
      --- @param item sia.Message?
      --- @param idx integer
    }, function(item, idx)
      if item then
        local content = item:get_content()
        if content then
          local buf = vim.api.nvim_create_buf(false, true)
          vim.bo[buf].ft = "markdown"
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
          vim.bo[buf].modifiable = false
          vim.api.nvim_buf_set_name(buf, item:get_description())
          local win
          if opts.peek then
            win = vim.api.nvim_open_win(buf, true, {
              relative = "win",
              focusable = true,
              style = "minimal",
              anchor = "SW",
              row = vim.o.lines,
              col = 0,
              width = vim.api.nvim_win_get_width(0) - 1,
              height = math.floor(vim.o.lines * 0.2),
              border = "single",
              title = item:get_description(),
              title_pos = "center",
            })
            vim.wo[win].wrap = true
            vim.keymap.set("n", opts.close_key or "q", function()
              vim.api.nvim_win_close(win, true)
            end, { buffer = buf })
          else
            vim.bo[buf].buftype = "acwrite"
            vim.bo[buf].modified = false
            vim.api.nvim_win_set_buf(0, buf)
            if opts.edit then
              vim.bo[buf].modifiable = split.conversation:is_instruction_editable(mappings[idx])
              vim.api.nvim_create_autocmd("BufWriteCmd", {
                buffer = buf,
                callback = function()
                  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                  local updated = split.conversation:update_instruction(mappings[idx], lines)
                  if updated then
                    vim.api.nvim_echo({ { "Instruction updated...", "Normal" } }, false, {})
                  end
                  vim.bo[buf].modified = false
                end,
              })
            end
          end
        end
      end
    end)
  end
end

function M.toggle()
  local last = SplitStrategy.last()
  if last and vim.api.nvim_buf_is_valid(last.buf) then
    local win = vim.fn.bufwinid(last.buf)
    if win ~= -1 and vim.api.nvim_win_is_valid(win) and #vim.api.nvim_list_wins() > 1 then
      vim.api.nvim_win_close(win, true)
    else
      vim.cmd(last.options.cmd)
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, last.buf)
    end
  end
end

function M.open_reply()
  local buf = vim.api.nvim_get_current_buf()
  local current = SplitStrategy.by_buf(buf)
  if current then
    vim.cmd("new")
    buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].ft = "markdown"
    vim.api.nvim_buf_set_name(buf, "*sia reply*" .. current.name)
    vim.api.nvim_win_set_height(win, 10)

    vim.keymap.set("n", "<CR>", function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      --- @type sia.config.Instruction
      local instruction = {
        role = "user",
        content = lines,
      }
      current.conversation:add_instruction(instruction, nil)
      require("sia.assistant").execute_strategy(current)
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf })
    vim.keymap.set("n", "q", function()
      vim.api.nvim_buf_delete(buf, { force = true })
    end, { buffer = buf })
  end
end

-- local symbol_cache = {
--   last_arg = nil,
--   symbols = nil,
-- }

--- @type table<string, { completion: (fun(s:string):string[]), execution: fun(args: string[], bang: boolean, c: sia.Conversation?):nil }>
local add_commands = {
  file = {
    completion = function(lead)
      return vim.fn.getcompletion(lead, "file")
    end,
    execution = function(args, bang, conversation)
      if #args == 0 then
        local files
        if conversation then
          files = conversation.files
        else
          files = utils.get_global_files()
        end
        print(table.concat(files, ", "))
      else
        if bang then
          if conversation then
            conversation.files = {}
          else
            utils.clear_global_files()
          end
        end
        local files = utils.glob_pattern_to_files(args)

        if conversation then
          conversation:add_files(files)
        else
          utils.add_global_files(files)
        end
      end
    end,
  },
  -- symbol = {
  --   completion = function(arg)
  --     local symbols
  --     if symbol_cache.last_arg and symbol_cache.symbols and vim.startswith(arg, symbol_cache.last_arg) then
  --       symbols = symbol_cache.symbols
  --     else
  --       symbols = require("sia.lsp").workspace_symbols({ arg })
  --     end
  --
  --     local commands = {}
  --     for _, symbol in ipairs(symbols or {}) do
  --       table.insert(commands, symbol.symbol.name)
  --     end
  --
  --     symbol_cache.last_arg = arg
  --     symbol_cache.symbols = symbols
  --
  --     return commands
  --   end,
  --
  --   execution = function(args, bang, conversation)
  --     symbol_cache.last_arg = nil
  --     symbol_cache.symbols = nil
  --
  --     if conversation == nil then
  --       vim.notify("No conversation")
  --     end
  --     local symbols = require("sia.lsp").workspace_symbols({ args[1] })
  --     print(vim.inspect(symbols))
  --     if symbols and #symbols > 0 then
  --       for _, symbol in ipairs(symbols or {}) do
  --         symbol = symbol.symbol
  --
  --         local buf = vim.uri_to_bufnr(symbol.location.uri)
  --         vim.fn.bufload(buf)
  --         local pos = {
  --           symbol.location.range.start.line,
  --           symbol.location.range["end"].line,
  --         }
  --         conversation:add_instruction(require("sia.instructions").context(buf, pos))
  --       end
  --     else
  --       vim.notify("No symbols")
  --     end
  --   end,
  -- },
}

function M.setup(options)
  config.setup(options)
  require("sia.mappings").setup()

  vim.api.nvim_create_user_command("SiaAdd", function(args)
    local split = SplitStrategy.by_buf()
    local fargs = args.fargs
    local command = add_commands[table.remove(fargs, 1)]
    if command then
      command.execution(fargs, args.bang, split and split.conversation or nil)
    end
  end, {
    nargs = "*",
    bang = true,
    bar = true,
    complete = function(arg_lead, line, pos)
      local complete = {}

      if string.sub(line, 1, pos):match("SiaAdd%s%w*$") then
        for command, _ in pairs(add_commands) do
          if vim.startswith(command, arg_lead) then
            complete[#complete + 1] = command
          end
        end
      else
        local command = add_commands[string.sub(line, 1, pos):match("SiaAdd%s+(%w*)")]
        if command then
          for _, subcmd in ipairs(command.completion(arg_lead)) do
            complete[#complete + 1] = subcmd
          end
        end
      end
      return complete
    end,
  })

  vim.api.nvim_create_user_command("SiaRemove", function(args)
    local split = SplitStrategy.by_buf()
    if split then
      split.conversation:remove_files(args.fargs)
    else
      utils.remove_global_files(args.fargs)
    end
  end, {
    nargs = "+",
    complete = function(arg_lead)
      local split = SplitStrategy.by_buf()
      local files
      if split then
        files = split.conversation.files
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

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "SiaError",
    callback = function(args)
      local data = args.data
      if data.message then
        if type(data.message) == "string" then
          vim.notify("Sia: " .. data.message, vim.log.levels.WARN)
        elseif data.message.error and type(data.message.error) == "string" then
          vim.notify("Sia: " .. data.message.error, vim.log.levels.WARN)
        end
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
--- @param opts sia.ActionContext
--- @param model string?
function M.main(action, opts, model)
  if vim.api.nvim_buf_is_loaded(opts.buf) then
    local strategy
    if vim.bo[opts.buf].filetype == "sia" then
      strategy = SplitStrategy.by_buf(opts.buf)
      if strategy then
        local last_instruction = action.instructions[#action.instructions] --[[@as sia.config.Instruction ]]
        strategy.conversation:add_instruction(last_instruction, opts)

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
