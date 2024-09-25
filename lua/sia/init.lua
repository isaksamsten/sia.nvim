local config = require("sia.config")
local utils = require("sia.utils")
local BufAppend = utils.BufAppend

local M = {}

local function get_position(type)
  local start_pos, end_pos
  if type == nil or type == "line" then
    start_pos = vim.fn.getpos("'[")
    end_pos = vim.fn.getpos("']")
  else
    start_pos = vim.fn.getpos("'<")
    end_pos = vim.fn.getpos("'>")
  end
  return start_pos, end_pos
end

local function make_sia_split(prompt)
  vim.cmd(prompt and prompt.split and prompt.split.cmd or config.options.default.split.cmd or "vsplit")
  local res_win = vim.api.nvim_get_current_win()
  local res_buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(res_win, res_buf)
  vim.api.nvim_buf_set_option(res_buf, "filetype", "sia")
  vim.api.nvim_buf_set_option(res_buf, "syntax", "markdown")
  vim.api.nvim_buf_set_option(res_buf, "buftype", "nowrite")
  vim.api.nvim_buf_set_name(res_buf, "*sia*")
  return res_win, res_buf
end

function _G.__sia_add_context(type)
  local start_pos, end_pos = get_position(type)
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local req_buf = vim.api.nvim_get_current_buf()
  local lines = require("sia.context").get_code(
    start_line,
    end_line,
    { bufnr = req_buf, show_line_numbers = true, return_table = true }
  )

  local filetype = vim.bo.ft
  local buf, win = utils.get_current_visible_sia_buffer()
  if not buf or not win then
    win, buf = make_sia_split(nil)
    local split_wo = config.options.default.split.wo
    if split_wo then
      for key, value in pairs(split_wo) do
        vim.api.nvim_win_set_option(win, key, value)
      end
    end
  end

  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "# User", "" })
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "```" .. filetype .. " " .. req_buf })
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "```", "", "" })
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

function _G.__sia_execute(type)
  local start_pos, end_pos = get_position(type)
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line == 0 or end_line == 0 then
    vim.notify("Empty selection")
    _G.__sia_execute_prompt = nil -- reset
    return
  end

  local opts = {
    start_line = start_line,
    end_line = end_line,
    mode = "v",
  }
  local prompt
  if _G.__sia_execute_prompt == nil and vim.b.sia then
    prompt = M.resolve_prompt({ vim.b.sia }, opts)
  elseif _G.__sia_execute_prompt then
    prompt = M.resolve_prompt({ _G.__sia_execute_prompt }, opts)
  end
  _G.__sia_execute_prompt = nil -- reset

  if prompt and not config._is_disabled(prompt) then
    M.main(prompt, opts)
  else
    vim.notify("Prompt is unavailable")
  end
end

function M.execute_op_with_prompt(prompt)
  _G.__sia_execute_prompt = prompt
  vim.cmd("set opfunc=v:lua.__sia_execute")
  return "g@"
end

function M.execute_visual_with_prompt(prompt, type)
  _G.__sia_execute_prompt = prompt
  _G.__sia_execute(type)
end

function M.setup(options)
  config.setup(options)
  vim.treesitter.language.register("markdown", "sia")
  vim.api.nvim_set_keymap(
    "n",
    "<Plug>(sia-append)",
    ":set opfunc=v:lua.__sia_add_context<CR>g@",
    { noremap = true, silent = true }
  )
  vim.api.nvim_set_keymap(
    "x",
    "<Plug>(sia-append)",
    ":<C-U>lua __sia_add_context(vim.fn.visualmode())<CR>",
    { noremap = true, silent = true }
  )
  vim.api.nvim_set_keymap(
    "n",
    "<Plug>(sia-execute)",
    ":set opfunc=v:lua.__sia_execute<CR>g@",
    { noremap = true, silent = true }
  )
  vim.api.nvim_set_keymap(
    "x",
    "<Plug>(sia-execute)",
    ":<C-U>lua __sia_execute(vim.fn.visualmode())<CR>",
    { noremap = true, silent = true }
  )

  for prompt, _ in pairs(config.options.prompts) do
    vim.api.nvim_set_keymap(
      "n",
      "<Plug>(sia-execute-" .. prompt .. ")",
      'v:lua.require("sia").execute_op_with_prompt("/' .. prompt .. '")',
      { noremap = true, silent = true, expr = true }
    )
    vim.api.nvim_set_keymap(
      "x",
      "<Plug>(sia-execute-" .. prompt .. ")",
      ":<C-U>lua require('sia').execute_visual_with_prompt('/" .. prompt .. "', vim.fn.visualmode())<CR>",
      { noremap = true, silent = true }
    )
  end

  local augroup_id = vim.api.nvim_create_augroup("SiaDetectCodeBlock", { clear = true })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup_id,
    pattern = "*",
    callback = function(args)
      if vim.bo.filetype == "sia" then
        require("sia.blocks").check_if_in_code_block(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup_id,
    pattern = "*",
    callback = function(args)
      if vim.bo[args.buf].filetype == "sia" then
        require("sia.blocks").remove_code_blocks(args.buf)
      end
    end,
  })
  if config.options.report_usage == true then
    vim.api.nvim_create_autocmd("User", {
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

--- Replaces string prompts with their corresponding named prompt tables.
---
--- This function iterates over a list of prompts and replaces any string prompts
--- with their corresponding named prompt tables as defined in the configuration.
---
--- @param prompts table A list of prompts, where each prompt can be either a string or a table.
--- @return table prompt list of prompts, with string prompts replaced by their corresponding named prompt tables.
local function replace_named_prompts(prompts)
  for i, prompt in ipairs(prompts) do
    if type(prompt) ~= "table" then
      prompts[i] = vim.deepcopy(config.options.named_prompts[prompt])
    end
  end
  return prompts
end

--- Resolves a given prompt based on configuration options and context.
--- This function handles both named prompts and ad-hoc prompts, adjusting the behavior
--- based on the current file type and provided options.
---
--- @param prompt table: A table containing the prompt to resolve. The first element can be a named prompt.
--- @param opts table: A table containing options that can influence the prompt resolution.
--- @return table|nil: Returns a table containing the resolved prompt configuration or nil if the prompt could not be resolved.
function M.resolve_prompt(prompt, opts)
  -- We have a named prompt
  if vim.startswith(prompt[1], "/") and vim.bo.ft ~= "sia" then
    local prompt_key = prompt[1]:sub(2)
    local prompt_config = vim.deepcopy(config.options.prompts[prompt_key])
    if prompt_config == nil then
      vim.notify(prompt[1] .. " does not exists")
      return nil
    end

    -- Some prompts require additional input from the user
    if prompt_config.input and prompt_config.input == "require" and #prompt < 2 then
      vim.notify(prompt[1] .. " requires input")
      return nil
    end

    -- Some prompts ignore additional input
    if #prompt > 1 and not (prompt_config.input and prompt_config.input == "ignore") then
      table.insert(prompt_config.prompt, { role = "user", content = table.concat(prompt, " ", 2) })
    end

    -- Replace any named prompt with the ones defined in the configuration
    prompt_config.prompt = replace_named_prompts(prompt_config.prompt)
    return prompt_config
  else -- We have an ad-hoc prompt
    -- Default to split that is to open the response in a new buffer
    local mode_prompt = "split"
    local prefix = false
    local suffix = false

    -- If the current filetype is sia, then we are in chat
    if vim.bo.ft == "sia" then
      mode_prompt = "chat"
    -- If bang use insert
    elseif config.options.default.mode == "insert" or opts.force_insert then
      mode_prompt = "insert"
      prefix = config.options.default.prefix
      suffix = config.options.default.suffix
    elseif -- in range mode we use diff
      config.options.default.mode == "diff" or (config.options.default.mode == "auto" and opts.mode == "v")
    then
      mode_prompt = "diff"
    end

    local mode_prompt_table = replace_named_prompts(vim.deepcopy(config.options.default.mode_prompt[mode_prompt]))
    table.insert(mode_prompt_table, { role = "user", content = table.concat(prompt, " ") })
    return {
      prompt = mode_prompt_table,
      prefix = prefix,
      suffix = suffix,
      temperature = config.options.default.temperature,
      model = config.options.default.model,
      mode = config.options.default.mode,
    }
  end
end

---
--- Collects user prompts from a given list of prompts.
---
--- This function iterates over a table of prompts and extracts the content
--- of prompts where the role is "user". Each prompt's content is split into
--- lines, and all lines are collected into a single table.
---
--- @param prompts A table containing prompts, where each prompt is expected to
--- have a 'role' and 'content' field.
--- @return table table containing lines of text extracted from user prompts.
--- Each line corresponds to a line in the content of the user prompts.
local function collect_user_prompts(prompts)
  local lines = {}
  for _, prompt in ipairs(prompts) do
    if prompt.role == "user" then
      for _, line in ipairs(vim.split(prompt.content, "\n", { plain = true, trimempty = false })) do
        table.insert(lines, line)
      end
    end
  end
  return lines
end

---
--- Creates a chat strategy for handling asynchronous job events and updating a buffer with the chat content.
---
--- @param buf number The buffer number where the chat content will be appended.
--- @param winnr number The window number where the buffer is displayed.
--- @param prompt table The initial prompt or message to start the chat.
---
--- @return table table containing functions to handle the start, progress, and completion of the job.
---  - table.on_start function A function to be called when the job starts.
---  - table.on_progress function A function to be called with content updates during the job's progress.
---  - table.on_complete function A function to be called when the job is complete.
local function chat_strategy(buf, winnr, prompt)
  if prompt.use_mode_prompt == false then
    local ok, system_prompt = pcall(vim.api.nvim_buf_get_var, buf, "sia_system_prompt")
    if not ok then
      system_prompt = prompt.prompt[1]
      vim.api.nvim_buf_set_var(buf, "sia_system_prompt", system_prompt)
    end
  end
  local buf_append = nil
  return {
    on_start = function(job)
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_set_option(buf, "modifiable", true)
        vim.api.nvim_buf_set_keymap(buf, "n", "x", "", {
          callback = function()
            vim.fn.jobstop(job)
          end,
        })
      end
    end,
    on_progress = function(content)
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        if buf_append == nil then
          local line_count = vim.api.nvim_buf_line_count(buf)
          vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { "# User", "" })
          vim.api.nvim_buf_set_lines(buf, -1, -1, false, collect_user_prompts(prompt.prompt))
          vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "# Assistant", "" })
          line_count = vim.api.nvim_buf_line_count(buf)
          buf_append = BufAppend:new(buf, line_count - 1, 0)
        end
        buf_append:append_to_buffer(content)
        if vim.api.nvim_win_is_valid(winnr) then
          vim.api.nvim_win_set_cursor(winnr, { buf_append.line + 1, buf_append.col })
        end
      end
    end,
    on_complete = function()
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "" })
        local line_count = vim.api.nvim_buf_line_count(buf)

        if vim.api.nvim_win_is_valid(winnr) then
          vim.api.nvim_win_set_cursor(winnr, { line_count, 0 })
        end
        vim.api.nvim_buf_del_keymap(buf, "n", "x")
        vim.api.nvim_buf_set_option(buf, "modifiable", false)
        require("sia.assistant").simple_query({
          {
            role = "system",
            content = "Summarize the interaction. Make it suitable for a buffer name in neovim using three to five words. Only output the name, nothing else.",
          },
          { role = "user", content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, true), "\n") },
        }, function(content)
          pcall(vim.api.nvim_buf_set_name, buf, "*sia* " .. content:lower():gsub("%s+", "-"))
        end)
        require("sia.blocks").detect_code_blocks(buf)
      end
    end,
  }
end

---
--- Resolves the placement start position for a window.
---
--- This function determines the starting line and placement type for a given window based on the provided options.
--- The placement can be specified directly or through a function or table.
---
--- @param win number: The window ID.
--- @param insert table|nil: A table containing options, or nil.
--- @param opts table: A table containing additional options. Must include `start_line`, `end_line`, and `mode`.
--- @return number, string: The starting line and placement type.
---
local function resolve_placement_start(win, insert, opts)
  local placement = insert and insert.placement or config.options.default.insert.placement
  if type(placement) == "function" then
    placement = placement()
  end

  if type(placement) == "table" then
    if placement[2] == "cursor" then
      return vim.api.nvim_win_get_cursor(win)[1], placement[1]
    elseif placement[2] == "start" then
      return opts.start_line, placement[1]
    else
      return opts.end_line, placement[1]
    end
  else
    if placement == "cursor" then
      return vim.api.nvim_win_get_cursor(win)[1], placement
    else
      if opts.mode == "v" then
        if placement == "above" then
          return opts.start_line, placement
        else
          return opts.end_line, placement
        end
      else
        return opts.start_line, placement
      end
    end
  end
end

function M.main(prompt, opts)
  local req_win = vim.api.nvim_get_current_win()
  local req_buf = vim.api.nvim_get_current_buf()
  local filetype = vim.bo.filetype

  -- First we try to establish the context of the request
  -- If prompt.context is a function we try to execute it
  -- and use the returned start and end lines.
  --
  -- Ignored if the use has already supplied a range.
  if prompt.context and opts.mode ~= "v" then
    local ok, lines = prompt.context(req_buf, opts)
    if not ok then
      vim.notify(lines) -- lines is an error message
      return
    end
    opts.start_line = lines.start_line
    opts.end_line = lines.end_line
  end

  local strategy
  local mode = prompt.mode or config.options.default.mode

  -- If the user has used a bang, we always use insert mode
  if opts.force_insert then
    mode = "insert"
  end

  if vim.api.nvim_buf_get_option(req_buf, "filetype") == "sia" and not opts.force_insert then
    local ok, system_prompt = pcall(vim.api.nvim_buf_get_var, req_buf, "sia_system_prompt")
    if ok then
      table.insert(prompt.prompt, 1, system_prompt)
    end
    if
      not ok
      and prompt.use_mode_prompt ~= false
      and config.options.named_prompts
      and config.options.named_prompts.split_system
    then
      table.insert(prompt.prompt, 1, config.options.named_prompts.split_system)
    end
    strategy = chat_strategy(req_buf, req_win, prompt)
  elseif mode == "replace" then
    if
      prompt.use_mode_prompt ~= false
      and config.options.named_prompts
      and config.options.named_prompts.insert_system
    then
      table.insert(prompt.prompt, 1, config.options.named_prompts.insert_system)
    end
    local buf_append = nil
    strategy = {
      on_progress = function(content)
        if vim.api.nvim_buf_is_valid(req_buf) and vim.api.nvim_buf_is_loaded(req_buf) then
          -- Join all changes to simplify undo
          if buf_append then
            vim.api.nvim_buf_call(req_buf, function()
              pcall(vim.cmd.undojoin)
            end)
          else
            buf_append = BufAppend:new(req_buf, opts.start_line - 1, 0)
          end

          buf_append:append_to_buffer(content)
        end
      end,

      on_start = function(job)
        if vim.api.nvim_buf_is_valid(req_buf) and vim.api.nvim_buf_is_loaded(req_buf) then
          vim.api.nvim_buf_set_lines(req_buf, opts.start_line - 1, opts.end_line, false, { "" })
          vim.api.nvim_buf_set_keymap(req_buf, "n", "x", "", {
            callback = function()
              vim.fn.jobstop(job)
            end,
          })
          vim.api.nvim_buf_set_keymap(req_buf, "i", "<c-x>", "", {
            callback = function()
              vim.fn.jobstop(job)
            end,
          })
        end
      end,
      on_complete = function()
        if vim.api.nvim_buf_is_valid(req_buf) and vim.api.nvim_win_is_valid(req_win) then
          vim.api.nvim_buf_del_keymap(req_buf, "n", "x")
          vim.api.nvim_buf_del_keymap(req_buf, "i", "<c-x>")
          if prompt.cursor and prompt.cursor == "start" then
            vim.api.nvim_win_set_cursor(req_win, { opts.start_line, 0 })
          elseif buf_append then
            vim.api.nvim_win_set_cursor(req_win, { buf_append.line + 1, buf_append.col })
          end
        end
      end,
    }
  elseif mode == "insert" then
    if
      prompt.use_mode_prompt ~= false
      and config.options.named_prompts
      and config.options.named_prompts.insert_system
    then
      table.insert(prompt.prompt, 1, config.options.named_prompts.insert_system)
    end
    local current_line, placement = resolve_placement_start(req_win, prompt.insert, opts)

    local buf_append = nil
    strategy = {
      on_progress = function(content)
        if vim.api.nvim_buf_is_valid(req_buf) and vim.api.nvim_buf_is_loaded(req_buf) then
          -- Join all changes to simplify undo
          if buf_append then
            vim.api.nvim_buf_call(req_buf, function()
              pcall(vim.cmd.undojoin)
            end)
          else
            local line = vim.api.nvim_buf_get_lines(req_buf, current_line - 1, current_line, false)
            buf_append = BufAppend:new(req_buf, current_line - 1, #line[1])
          end

          buf_append:append_to_buffer(content)
        end
      end,

      on_start = function(job)
        if vim.api.nvim_buf_is_valid(req_buf) and vim.api.nvim_buf_is_loaded(req_buf) then
          if placement and placement == "below" then
            vim.api.nvim_buf_set_lines(req_buf, current_line, current_line, false, { "" })
            current_line = current_line + 1
          elseif placement and placement == "above" then
            vim.api.nvim_buf_set_lines(req_buf, current_line - 1, current_line - 1, false, { "" })
          else
            -- Add to end of line
          end
          vim.api.nvim_buf_set_keymap(req_buf, "n", "x", "", {
            callback = function()
              vim.fn.jobstop(job)
            end,
          })
        end
      end,
      on_complete = function()
        if vim.api.nvim_buf_is_valid(req_buf) and vim.api.nvim_win_is_valid(req_win) then
          vim.api.nvim_buf_del_keymap(req_buf, "n", "x")
          if prompt.cursor and prompt.cursor == "start" then
            vim.api.nvim_win_set_cursor(req_win, { opts.start_line, 0 })
          elseif buf_append then
            vim.api.nvim_win_set_cursor(req_win, { buf_append.line + 1, buf_append.col })
          end
        end
      end,
    }
  elseif mode == "diff" or (mode == "auto" and opts.mode == "v") then
    if
      prompt.use_mode_prompt ~= false
      and config.options.named_prompts
      and config.options.named_prompts.diff_system
    then
      table.insert(prompt.prompt, 1, config.options.named_prompts.diff_system)
    end

    vim.cmd("vsplit")
    local res_win = vim.api.nvim_get_current_win()
    local res_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(res_win, res_buf)
    vim.api.nvim_buf_set_option(res_buf, "filetype", filetype)

    for _, wo in pairs(prompt.diff and prompt.diff.wo or config.options.default.diff.wo or {}) do
      vim.api.nvim_win_set_option(res_win, wo, vim.api.nvim_win_get_option(req_win, wo))
    end

    -- Partition request buffer
    local before_context = vim.api.nvim_buf_get_lines(req_buf, 0, opts.start_line - 1, true)
    local after_context = vim.api.nvim_buf_get_lines(req_buf, opts.end_line, -1, true)

    -- Add line before the response
    vim.api.nvim_buf_set_lines(res_buf, 0, 0, true, before_context)
    vim.api.nvim_win_set_cursor(res_win, { opts.start_line, 0 })

    local buf_append = BufAppend:new(res_buf, opts.start_line - 1, 0)
    strategy = {
      on_complete = function()
        if vim.api.nvim_buf_is_valid(res_buf) and vim.api.nvim_buf_is_loaded(res_buf) then
          -- Add line after the response
          vim.api.nvim_buf_set_lines(res_buf, -1, -1, true, after_context)

          if vim.api.nvim_win_is_valid(res_win) and vim.api.nvim_win_is_valid(req_win) then
            vim.api.nvim_set_current_win(res_win)
            vim.cmd("diffthis")
            vim.api.nvim_set_current_win(req_win)
            vim.cmd("diffthis")
          end

          vim.api.nvim_buf_del_keymap(res_buf, "n", "x")
          vim.api.nvim_buf_set_option(res_buf, "modifiable", false)
        end
      end,
      on_progress = function(content)
        if vim.api.nvim_buf_is_valid(res_buf) and vim.api.nvim_buf_is_loaded(res_buf) then
          buf_append:append_to_buffer(content)
          if vim.api.nvim_win_is_valid(res_win) then
            vim.api.nvim_win_set_cursor(res_win, { buf_append.line + 1, buf_append.col })
          end
        end
      end,
      on_start = function(job)
        vim.api.nvim_buf_set_keymap(res_buf, "n", "x", "", {
          callback = function()
            vim.fn.jobstop(job)
          end,
        })
      end,
    }
  elseif mode == "split" or (mode == "auto" and opts.mode == "n") then
    local res_win, res_buf = make_sia_split()
    local split_wo = prompt.wo or config.options.default.split.wo
    if split_wo then
      for key, value in pairs(split_wo) do
        vim.api.nvim_win_set_option(res_win, key, value)
      end
    end

    if
      prompt.use_mode_prompt ~= false
      and config.options.named_prompts
      and config.options.named_prompts.split_system
    then
      table.insert(prompt.prompt, 1, config.options.named_prompts.split_system)
    end
    strategy = chat_strategy(res_buf, res_win, prompt)
  else
    vim.notify("invalid mode")
    return
  end

  if vim.api.nvim_buf_is_valid(req_buf) and vim.api.nvim_buf_is_loaded(req_buf) then
    local context, context_suffix
    -- If the user has given a range or a context get the context delineated by
    -- the range or the context
    if opts.mode == "v" or prompt.context ~= nil then
      context = table.concat(vim.api.nvim_buf_get_lines(req_buf, opts.start_line - 1, opts.end_line, true), "\n")
    else
      -- Otherwise, we use the context surrounding the current line given by
      -- prefix and suffix
      local start_line
      if prompt.prefix and prompt.prefix ~= false then
        start_line = math.max(0, opts.start_line - prompt.prefix)
      else
        start_line = opts.start_line - (config.options.default.prefix or 1)
      end
      if prompt.prefix ~= false then
        context = table.concat(vim.api.nvim_buf_get_lines(req_buf, start_line, opts.start_line, true), "\n")
      else
        context = ""
      end

      local suffix = prompt.suffix or config.options.suffix
      if suffix and suffix > 0 then
        local line_count = vim.api.nvim_buf_line_count(req_buf)
        local end_line = math.min(line_count, opts.end_line + prompt.suffix)
        context_suffix = table.concat(vim.api.nvim_buf_get_lines(req_buf, opts.end_line - 1, end_line, true), "\n")
      else
        context_suffix = ""
      end
    end

    local ft = vim.api.nvim_buf_get_option(req_buf, "filetype")
    local replacement = {
      filetype = ft,
      filepath = vim.api.nvim_buf_get_name(req_buf),
      context = context,
      context_suffix = context_suffix,
    }
    opts.buf = req_buf
    opts.ft = filetype
    opts.filepath = replacement.filepath
    opts.context = context
    local steps_to_remove = {}
    for i, step in ipairs(prompt.prompt) do
      if type(step.content) == "function" then
        step.content = step.content(opts)
      end
      step.content = step.content:gsub("{{(.-)}}", function(key)
        return replacement[key] or key
      end)
      if step.content == "" then
        table.insert(steps_to_remove, i)
      end
    end

    for _, step in ipairs(steps_to_remove) do
      table.remove(prompt.prompt, step)
    end
    if config.options.debug then
      print(vim.inspect(prompt))
    end
    require("sia.assistant").query(prompt, strategy.on_start, strategy.on_progress, strategy.on_complete)
  end
end

return M
