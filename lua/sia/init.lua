local config = require("sia.config")
local utils = require("sia.utils")
local BufAppend = utils.BufAppend

local M = {}

-- TODO: Keep track of all sia-buffers variables and attached contexts instead of relying on buffer-variables.
-- 1.
local BufferTracker = {}
BufferTracker._open_buffers = {}

function BufferTracker.add(buf, win)
  table.insert(BufferTracker._open_buffers, { buf = buf, win = win })
end

function BufferTracker.pop()
  return table.remove(BufferTracker._open_buffers)
end

function BufferTracker.last()
  return BufferTracker._open_buffers[#BufferTracker._open_buffers]
end

function BufferTracker.remove(buf)
  for i, open in ipairs(BufferTracker._open_buffers) do
    if open.buf == buf then
      table.remove(BufferTracker._open_buffers, i)
      return true
    end
  end
  return false
end

function BufferTracker.count()
  return #BufferTracker._open_buffers
end

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
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_option(buf, "filetype", "sia")
  vim.api.nvim_buf_set_option(buf, "syntax", "markdown")
  vim.api.nvim_buf_set_option(buf, "buftype", "nowrite")
  local status, _ = pcall(vim.api.nvim_buf_set_name, buf, "*sia*")
  if not status then
    vim.api.nvim_buf_set_name(buf, "*sia* " .. BufferTracker.count())
  end
  BufferTracker.add(buf, win)
  return win, buf
end

function _G.__sia_add_buffer()
  local status = utils.add_message(nil, require("sia.messages").current_buffer(true), {
    buf = vim.api.nvim_get_current_buf(),
    mode = "n",
    ft = vim.bo.ft,
    start_line = 1,
    end_line = -1,
    context_is_buffer = true,
  })
  if not status then
    vim.notify("Can't determine *sia* buffer")
  end
end

function _G.__sia_add_context(type)
  local start_pos, end_pos = get_position(type)
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  if start_line > 0 then
    local req_buf = vim.api.nvim_get_current_buf()

    local status = utils.add_message(nil, require("sia.messages").current_context(true), {
      buf = req_buf,
      mode = "v",
      ft = vim.bo.ft,
      start_line = start_line,
      end_line = end_line,
      context_is_buffer = end_line == vim.api.nvim_buf_line_count(req_buf),
    })
    if not status then
      vim.notify("Can't determine *sia* buffer")
    end
  end
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
  vim.keymap.set("n", "<Plug>(sia-toggle)", function()
    local last = BufferTracker.last()
    if last and vim.api.nvim_buf_is_valid(last.buf) then
      if not vim.api.nvim_win_is_valid(last.win) then
        vim.cmd(config.options.default.split.cmd)
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, last.buf)
        last.win = win
      else
        if #vim.api.nvim_list_wins() > 1 then
          vim.api.nvim_win_close(last.win, true)
        end
      end
    end
  end, { noremap = true, silent = true })
  vim.api.nvim_set_keymap(
    "n",
    "<Plug>(sia-append-buffer)",
    ":lua __sia_add_buffer()<CR>",
    { noremap = true, silent = true }
  )
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

  local blocks_augroup = vim.api.nvim_create_augroup("SiaDetectCodeBlock", { clear = true })
  local blocks_augroup = vim.api.nvim_create_augroup("SiaOnTyping", { clear = true })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = blocks_augroup,
    pattern = "*",
    callback = function(args)
      if vim.bo.filetype == "sia" then
        require("sia.blocks").check_if_in_code_block(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = blocks_augroup,
    pattern = "*",
    callback = function(args)
      if vim.bo[args.buf].filetype == "sia" then
        require("sia.blocks").remove_code_blocks(args.buf)
        BufferTracker.remove(args.buf)
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
    local mode_prompt
    local prefix = false
    local suffix = false

    -- If the current filetype is sia, then we are in chat
    if vim.bo.ft == "sia" then
      mode_prompt = "chat"
    elseif opts.bang and opts.mode == "n" then
      mode_prompt = "insert"
      prefix = config.options.default.prefix
      suffix = config.options.default.suffix
    elseif opts.bang and opts.mode == "v" then
      mode_prompt = "diff"
    else
      mode_prompt = "split"
    end

    mode_prompt = vim.deepcopy(config.options.default.mode_prompt[mode_prompt])
    mode_prompt.prompt = replace_named_prompts(mode_prompt.prompt)
    table.insert(mode_prompt.prompt, { role = "user", content = table.concat(prompt, " ") })
    mode_prompt.prefix = prefix
    mode_prompt.suffix = suffix
    return mode_prompt
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
      if prompt.hidden == nil or prompt.hidden == false then
        -- local content = nil
        -- if type(prompt.hidden) == "function" then
        --   local hidden_text = prompt.hidden()
        --   if hidden_text ~= nil and hidden_text ~= "" then
        --     content = string.format("```hidden\n%s\n```", hidden_text)
        --   end
        -- else
        --   content = prompt.content
        -- end
        local content = prompt.content
        if content then
          for _, line in ipairs(vim.split(content, "\n", { plain = true, trimempty = false })) do
            table.insert(lines, line)
          end
        end
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
  local ok, _ = pcall(vim.api.nvim_buf_get_var, buf, "_sia_prompt")
  if not ok then
    vim.api.nvim_buf_set_var(buf, "_sia_prompt", prompt)
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
          vim.api.nvim_buf_set_lines(buf, line_count - 1, line_count, false, { "# User" })
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
        utils.add_hidden_prompts(buf, prompt.prompt)
        vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "", "" })
        local line_count = vim.api.nvim_buf_line_count(buf)

        if vim.api.nvim_win_is_valid(winnr) then
          vim.api.nvim_win_set_cursor(winnr, { line_count, 0 })
        end
        vim.api.nvim_buf_del_keymap(buf, "n", "x")
        vim.api.nvim_buf_set_option(buf, "modifiable", false)
        vim.schedule(function()
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
        end)
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

local function finalize_prompt(prompt, replacement)
  local steps_to_remove = {}
  for i, step in ipairs(prompt.prompt) do
    if type(step.content) == "function" then
      step.content = step.content()
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
end

local function prepare_prompt(req_buf, prompt, opts)
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
  if opts.start_line == 1 and opts.end_line == vim.api.nvim_buf_line_count(req_buf) then
    opts.context_is_buffer = true
  end

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
  opts.context = context
  opts.context_suffix = context_suffix
  opts.buf = req_buf
  opts.ft = ft
  opts.filepath = vim.api.nvim_buf_get_name(req_buf)

  -- Memoize functions
  for _, step in ipairs(prompt.prompt) do
    if type(step.content) == "function" then
      local content = step.content
      step.content = function()
        return content(opts)
      end
      if step.hidden and type(step.hidden) == "function" then
        local hidden = step.hidden
        step.hidden = function()
          return hidden(opts)
        end
      end
    end
  end
end

function M.main(prompt, opts)
  local req_win = vim.api.nvim_get_current_win()
  local req_buf = vim.api.nvim_get_current_buf()

  if vim.api.nvim_buf_is_valid(req_buf) and vim.api.nvim_buf_is_loaded(req_buf) then
    -- modifies the prompt and opts
    prepare_prompt(req_buf, prompt, opts)

    local strategy
    local mode = prompt.mode

    -- If the user has used a bang, we always use insert mode
    if not mode then
      if opts.bang and opts.mode == "n" then
        mode = "insert"
      elseif opts.bang and opts.mode == "v" then
        mode = "diff"
      else
        mode = "split"
      end
    end

    -- Request initiated from *sia*-buffer this is a chat message
    if vim.api.nvim_buf_get_option(req_buf, "filetype") == "sia" then
      local ok, buffer_prompt = pcall(vim.api.nvim_buf_get_var, req_buf, "_sia_prompt")
      if ok then
        if #buffer_prompt.prompt > 1 then
          for i = #buffer_prompt.prompt, 1, -1 do
            local item = buffer_prompt.prompt[i]
            if item.reuse then
              table.insert(prompt.prompt, 1, item)
            end
          end
        end
        if buffer_prompt.temperature and type(buffer_prompt.temperature) == "table" then
          prompt.temperature = buffer_prompt.temperature[false]
        elseif buffer_prompt.temperature then
          prompt.temperature = buffer_prompt.temperature
        end
        prompt.model = buffer_prompt.model
      end
      strategy = chat_strategy(req_buf, req_win, prompt)
    elseif mode == "replace" then
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
    elseif mode == "diff" then
      vim.cmd("vsplit")
      local res_win = vim.api.nvim_get_current_win()
      local res_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_win_set_buf(res_win, res_buf)
      vim.api.nvim_buf_set_option(res_buf, "filetype", opts.ft)

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
    elseif mode == "split" then
      local res_win, res_buf = make_sia_split()
      local split_wo = prompt.wo or config.options.default.split.wo
      if split_wo then
        for key, value in pairs(split_wo) do
          vim.api.nvim_win_set_option(res_win, key, value)
        end
      end

      strategy = chat_strategy(res_buf, res_win, prompt)
    else
      vim.notify("invalid mode")
      return
    end

    finalize_prompt(prompt, {
      filetype = opts.ft,
      filepath = opts.filepath,
      context = opts.context,
      context_suffix = opts.context_suffix,
    })
    if config.options.debug then
      print(vim.inspect(prompt))
    end
    vim.schedule(function()
      require("sia.assistant").query(prompt, strategy.on_start, strategy.on_progress, strategy.on_complete)
    end)
  end
end

return M
