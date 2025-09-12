local M = {}

---@class SiaNewToolOpts
---@field name string
---@field description string
---@field read_only boolean?
---@field auto_apply (fun(args: table, conversation:sia.Conversation):integer?)?
---@field message string|(fun(args:table):string)?
---@field system_prompt string?
---@field required string[]
---@field parameters table
---@field confirm (string|fun(args:table):string)?
---@field select { prompt: (string|fun(args:table):string)?, choices: string[]}?
---@field require_confirmation (boolean|fun(args:table):boolean)?

---@param opts SiaNewToolOpts
---@param execute fun(args: table, conversation: sia.Conversation, callback: (fun(result: sia.ToolResult):nil), opts: {choice: integer?, cancellable: sia.Cancellable?}?)
---@return sia.config.Tool
M.new_tool = function(opts, execute)
  local auto_apply = function(args, conversation)
    --- Ensure that we auto apply incorrect tool calls
    if vim.iter(opts.required):any(function(required)
      return args[required] == nil
    end) then
      return 0
    end

    if conversation.auto_confirm_tools[opts.name] then
      return 1
    else
      return (opts.auto_apply and opts.auto_apply(args, conversation)) or nil
    end
  end

  --- @return boolean
  local require_confirmation = function(args)
    if not opts.require_confirmation then
      return false
    end
    if type(opts.require_confirmation) == "function" then
      return opts.require_confirmation(args)
    end
    return opts.require_confirmation
  end

  --- @type sia.config.Tool
  return {
    name = opts.name,
    message = opts.message,
    parameters = opts.parameters,
    system_prompt = opts.system_prompt,
    allow_parallel = function(conversation, args)
      if conversation.ignore_tool_confirm and opts.read_only then
        return true
      end

      if not opts.read_only then
        return false
      end

      -- Read-only tools are only parallel if they are auto applied
      -- or without confirmation
      if opts.confirm ~= nil or opts.select ~= nil then
        return auto_apply(args, conversation) ~= nil
      end
      return true
    end,
    description = opts.description,
    required = opts.required,
    execute = function(args, conversation, callback, cancellable)
      local should_confirm = opts.confirm ~= nil
      if conversation.ignore_tool_confirm then
        should_confirm = false
      end
      if should_confirm then
        if auto_apply(args, conversation) then
          execute(args, conversation, callback, { cancellable = cancellable })
          return
        end

        local text
        if type(opts.confirm) == "function" then
          text = opts.confirm(args)
        else
          text = opts.confirm
        end

        if text == nil then
          text = "Execute " .. (opts.name or "tool")
        end

        --- @cast text string
        local text_no_whitespace = text:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
        local text_sub = text_no_whitespace:sub(1, 80)

        local must_confirm = require_confirmation(args)

        local clear_confirmation = nil
        local prompt_text
        if #text_no_whitespace ~= #text_sub and must_confirm then
          clear_confirmation =
            require("sia.confirmation").show(vim.split(text, "\n", { trimempty = true, plain = true }))
          vim.cmd.redraw()
          prompt_text = "Proceed? (y/N): "
        elseif must_confirm then
          prompt_text = text_sub .. " - Proceed? (y/N): "
        else
          prompt_text = text_sub .. " - Proceed? (Y/n/[a]lways): "
        end

        vim.ui.input({
          prompt = prompt_text,
        }, function(resp)
          if clear_confirmation then
            clear_confirmation()
          end
          if resp == nil then
            callback({
              content = {
                string.format("User cancelled %s operation. Ask the user what they want you to do!", opts.name),
              },
            })
            return
          end

          local response = resp:lower():gsub("^%s*(.-)%s*$", "%1")
          if response == "n" or response == "no" then
            callback({
              content = {
                string.format("User declined to execute %s. Ask the user what they want you to do!", opts.name),
              },
            })
            return
          end

          if not must_confirm and (response == "a" or response == "always") then
            conversation.auto_confirm_tools[opts.name] = 1
            execute(args, conversation, callback, { cancellable = cancellable })
            return
          end

          local should_proceed = false
          if must_confirm then
            should_proceed = response == "y" or response == "yes"
          else
            should_proceed = response == "" or response == "y" or response == "yes"
          end

          if should_proceed then
            execute(args, conversation, callback, { cancellable = cancellable })
          else
            callback({
              content = {
                string.format("User declined to execute %s. Ask the user what they want you to do!", opts.name),
              },
            })
          end
        end)
      elseif opts.select then
        local auto_applied_choice = auto_apply(args, conversation)
        if auto_applied_choice then
          execute(args, conversation, callback, { choice = auto_applied_choice, cancellable = cancellable })
        else
          local prompt
          if type(opts.select.prompt) == "function" then
            prompt = opts.select.prompt(args)
          else
            prompt = opts.select.prompt
          end
          vim.ui.select(
            opts.select.choices,
            { prompt = string.format("%s\nChoose an action (Esc to cancel):", prompt) },
            function(_, idx)
              if idx == nil or idx < 1 or idx > #opts.select.choices then
                callback({ content = { string.format("User cancelled %s operation.", opts.name) } })
                return
              end
              execute(args, conversation, callback, { choice = idx, cancellable = cancellable })
            end
          )
        end
      else
        execute(args, conversation, callback)
      end
    end,
  }
end

return M
