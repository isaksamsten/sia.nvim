local M = {}

---@class sia.NewToolOpts
---@field name string
---@field description string
---@field read_only boolean?
---@field auto_apply (fun(args: table, conversation:sia.Conversation):integer?)?
---@field message string|(fun(args:table):string)?
---@field system_prompt string?
---@field required string[]
---@field parameters table

--- @class sia.NewToolExecuteUserChoiceOpts
--- @field choices string[]
--- @field on_accept fun(choice:integer):nil
--- @field must_confirm boolean?

--- @class sia.NewToolExecuteUserInputOpts
--- @field on_accept fun():nil
--- @field must_confirm boolean?

--- @alias sia.NewToolExecuteUserInput fun(prompt: string, opts: sia.NewToolExecuteUserInputOpts):nil
--- @alias sia.NewToolExecuteUserChoice fun(prompt: string, opts: sia.NewToolExecuteUserChoiceOpts):nil
--- @class sia.NewToolExecuteOpts
--- @field cancellable sia.Cancellable?
--- @field user_input sia.NewToolExecuteUserInput
--- @field user_choice sia.NewToolExecuteUserChoice

---@param opts sia.NewToolOpts
---@param execute fun(args: table, conversation: sia.Conversation, callback: (fun(result: sia.ToolResult):nil), opts: sia.NewToolExecuteOpts?)
---@return sia.config.Tool
M.new_tool = function(opts, execute)
  local auto_apply = function(args, conversation)
    if conversation.auto_confirm_tools[opts.name] then
      return 1
    else
      return (opts.auto_apply and opts.auto_apply(args, conversation)) or nil
    end
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

      return auto_apply(args, conversation) ~= nil
    end,
    description = opts.description,
    required = opts.required,
    execute = function(args, conversation, callback, cancellable)
      --- @type sia.NewToolExecuteUserInput
      local user_input

      --- @type sia.NewToolExecuteUserChoice
      local user_choice

      local auto_apply_choice = auto_apply(args, conversation)
      user_input = function(prompt, input_args)
        if (conversation.ignore_tool_confirm or auto_apply_choice) and not input_args.must_confirm then
          input_args.on_accept()
          return
        end

        if prompt == nil then
          prompt = "Execute " .. (opts.name or "tool")
        end

        local confirmation_text
        if input_args.must_confirm then
          confirmation_text = "Proceed? (y/N): "
        else
          confirmation_text = "Proceed? (Y/n/[a]lways): "
        end

        local clear_confirmation
        if #prompt > 80 or prompt:find("\n") then
          clear_confirmation =
            require("sia.confirmation").show(vim.split(prompt, "\n", { trimempty = true, plain = true }))
          vim.cmd.redraw()
        else
          confirmation_text = string.format("%s - %s", prompt, confirmation_text)
        end

        vim.ui.input({ prompt = confirmation_text }, function(resp)
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

          if not input_args.must_confirm and (response == "a" or response == "always") then
            conversation.auto_confirm_tools[opts.name] = 1
            input_args.on_accept()
            return
          end

          local should_proceed = false
          if input_args.must_confirm then
            should_proceed = response == "y" or response == "yes"
          else
            should_proceed = response == "" or response == "y" or response == "yes"
          end

          if should_proceed then
            input_args.on_accept()
          else
            callback({
              content = {
                string.format("User declined to execute %s. Ask the user what they want you to do!", opts.name),
              },
            })
          end
        end)
      end
      user_choice = function(prompt, choice_args)
        if auto_apply_choice and not choice_args.must_confirm then
          choice_args.on_accept(auto_apply_choice)
          return
        end
        vim.ui.select(
          choice_args.choices,
          { prompt = string.format("%s\nChoose an action (Esc to cancel):", prompt) },
          function(_, idx)
            if idx == nil or idx < 1 or idx > #choice_args.choices then
              callback({ content = { string.format("User cancelled %s operation.", opts.name) } })
              return
            end
            choice_args.on_accept(idx)
          end
        )
        -- end
      end
      execute(args, conversation, callback, {
        cancellable = cancellable,
        user_input = user_input,
        user_choice = user_choice,
      })
    end,
  }
end

return M
