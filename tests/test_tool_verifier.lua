local child = MiniTest.new_child_neovim()
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({ hooks = {
  pre_case = function()
    child.restart({ "-u", "assets/minimal.lua", "-i", "NONE", "-n" })
    child.lua([[
      local config = require("sia.config")
      config.get_local_config = function() return nil end
      config.options.settings.tool_verifier = { enable = true }
      config.options.settings.ui.confirm.async.enable = true
      config.options.settings.ui.confirm.use_vim_ui = false
      config.options.settings.ui.confirm.show_preview = true
      local permissions = require("sia.permissions")
      permissions.resolve_permissions = function() return nil end
      permissions.resolve_verifier_level = function() return _G.test_threshold end
      permissions.resolve_verifier_actions = function() return _G.test_approved_actions or {} end
      _G.test_verdict = {
        level = "medium", action = "Check the project workspace",
        reason = "Executes project code and may create generated files.", authorized = false,
      }
      _G.executions, _G.previews, _G.cleared = 0, {}, 0
      _G.confirmation_events = {}
      _G.verification_events = {}
      require("sia.assistant").fetch_response = function(conversation, opts)
        _G.assessed_model = conversation.model.name
        _G.assessed_input = vim.json.decode(conversation:get_last_user_content())
        _G.assessed_schema = opts.response_format.json_schema.schema
        opts.on_complete(_G.verifier_response or vim.json.encode(_G.test_verdict))
      end
      require("sia.ui.confirm").show = function(_, prompt, opts)
        _G.approval_prompt, _G.approval = prompt, opts
      end
      require("sia.preview").show = function(content, opts)
        local buf = vim.api.nvim_create_buf(false, true)
        if type(content) == "function" then
          content(buf)
        else
          vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
        end
        table.insert(_G.previews, {
          lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false), ft = vim.bo[buf].filetype, opts = opts,
        })
        vim.api.nvim_buf_delete(buf, { force = true })
        return function() _G.cleared = _G.cleared + 1 end
      end
      vim.ui.select = function(_, opts, callback)
        _G.selection_prompt, _G.choose = opts.prompt, callback
      end
      vim.ui.input = function(opts, callback)
        _G.input_prompt, _G.answer = opts.prompt, callback
      end
      _G.command = "printf '%s\\n' '```'\npwd"
      _G.start_bash = function()
        local proc
        local runtime = {
          pwd = function() return "/project" end,
          exec = function(_, cmd)
            _G.executions = _G.executions + 1
            proc = { id = 1, kind = "finished", outcome = "completed", code = 0, command = cmd }
            return proc
          end,
          get = function() return proc end,
          get_output = function() return { stdout = "done", stderr = "" } end,
        }
        local conversation = _G.test_conversation or require("sia.conversation").new({})
        conversation.process_runtime = runtime
        require("sia.tools.bash").implementation.execute({
          command = _G.command, description = "Run shell checks",
        }, function(result) _G.result = result end, {
          conversation = conversation,
          on_confirmation = function(waiting) table.insert(_G.confirmation_events, waiting) end,
          on_verification = function(active) table.insert(_G.verification_events, active) end,
        })
      end
    ]])
  end,
  post_case = function() child.stop() end,
} })

T["verification reports transient activity without requesting confirmation"] = function()
  child.lua([[
    require("sia.assistant").fetch_response = function(_, opts)
      _G.finish_assessment = opts.on_complete
    end
    start_bash()
  ]])
  eq({ true }, child.lua_get("verification_events"))
  eq({}, child.lua_get("confirmation_events"))
  eq(0, child.lua_get("executions"))
  child.lua("test_verdict.authorized = true; finish_assessment(vim.json.encode(test_verdict))")
  eq({ true, false }, child.lua_get("verification_events"))
  eq({}, child.lua_get("confirmation_events"))
  eq(1, child.lua_get("executions"))
end

T["malformed verification clears transient activity before prompting"] = function()
  child.lua("verifier_response = 'invalid'; start_bash()")
  eq({ true, false }, child.lua_get("verification_events"))
  eq({ true }, child.lua_get("confirmation_events"))
end

T["verification uses the verify role model"] = function()
  child.lua([[
    local config = require("sia.config")
    config.options.settings.model = {
      default = "openai/gpt-4.1",
      verify = "openai/gpt-5.2",
    }
    start_bash()
  ]])
  eq("openai/gpt-5.2", child.lua_get("assessed_model"))
end

T["unconfigured verification role falls back to the default mini tier"] = function()
  child.lua([[
    require("sia.config").options.settings.model = {
      default = { default = "openai/gpt-5.2", mini = "openai/gpt-4.1" },
    }
    start_bash()
  ]])
  eq("openai/gpt-4.1", child.lua_get("assessed_model"))
end

T["verification receives the latest user query"] = function()
  child.lua([[
    test_conversation = require("sia.conversation").new({})
    test_conversation:add_user_message("Run all tests")
    test_conversation:add_user_message("Only run the shell checks")
    test_conversation:add_assistant_message("I will run those checks.")
    start_bash()
  ]])
  eq("Only run the shell checks", child.lua_get("assessed_input.user_query"))
  eq(child.lua_get("command"), child.lua_get("vim.json.decode(assessed_input.tool_input).command"))
end

T["verification handles conversations without a user query"] = function()
  child.lua("start_bash()")
  eq("", child.lua_get("assessed_input.user_query"))
end

T["verification extracts text from the latest multipart user query"] = function()
  child.lua([[
    test_conversation = require("sia.conversation").new({})
    test_conversation:add_user_message({
      { type = "text", text = "Run shell checks" },
      { type = "text", text = "without changing files" },
    })
    local dropped = test_conversation:add_user_message("Run everything")
    dropped.dropped = true
    start_bash()
  ]])
  eq("Run shell checks\nwithout changing files", child.lua_get("assessed_input.user_query"))
end

for _, async in ipairs({ true, false }) do
  local mode = async and "async" or "synchronous"
  T[mode .. " authorized operations skip prompts even at high risk"] = function()
    child.lua(string.format([[
      require("sia.config").options.settings.ui.confirm.async.enable = %s
      test_threshold = "low"
      test_verdict.level = "high"
      test_verdict.authorized = true
      test_conversation = require("sia.conversation").new({})
      test_conversation:add_user_message("Run shell checks")
      start_bash()
    ]], tostring(async)))
    eq(1, child.lua_get("executions"))
    eq({}, child.lua_get("confirmation_events"))
    eq(0, child.lua_get("#previews"))
    eq(true, child.lua_get("result.verification.authorized"))
    eq("high", child.lua_get("result.verification.level"))
  end

  T[mode .. " approved actions use the same authorization decision"] = function()
    child.lua(string.format([[
      require("sia.config").options.settings.ui.confirm.async.enable = %s
      test_approved_actions = { "Run shell checks" }
      test_verdict.authorized = true
      start_bash()
    ]], tostring(async)))
    eq({ "Run shell checks" }, child.lua_get("assessed_input.approved_actions"))
    eq(1, child.lua_get("executions"))
    eq({}, child.lua_get("confirmation_events"))
  end

  T[mode .. " missing authorization falls back to manual approval"] = function()
    child.lua(string.format([[
      require("sia.config").options.settings.ui.confirm.async.enable = %s
      test_threshold = "high"
      test_verdict.authorized = nil
      start_bash()
    ]], tostring(async)))
    eq(0, child.lua_get("executions"))
    eq({ true }, child.lua_get("confirmation_events"))
  end
end

T["verifier schema requires a single authorization boolean"] = function()
  child.lua("start_bash()")
  eq({ type = "boolean" }, child.lua_get("assessed_schema.properties.authorized"))
  eq(true, child.lua_get("vim.tbl_contains(assessed_schema.required, 'authorized')"))
  eq(true, child.lua_get("assessed_schema.properties.matches_approved_action == nil"))
end

T["async approval uses AI description and previews exact command plus risk"] = function()
  child.lua("start_bash(); approval.on_preview()")
  eq("Check the project workspace", child.lua_get("approval_prompt"))
  eq(0, child.lua_get("executions"))
  eq({ true }, child.lua_get("confirmation_events"))
  local preview = child.lua_get("previews[1]")
  eq("markdown", preview.ft)
  local text = table.concat(preview.lines, "\n")
  eq(true, text:find("````sh\n" .. child.lua_get("command") .. "\n````", 1, true) ~= nil)
  eq(true, text:find("Working directory: /project", 1, true) ~= nil)
  eq(true, text:find("**Level:** medium", 1, true) ~= nil)
  eq(true, text:find("Executes project code and may create generated files.", 1, true) ~= nil)
  eq(true, preview.opts.wrap)
  child.lua("approval.on_accept()")
  eq(1, child.lua_get("executions"))
  eq({ true, false }, child.lua_get("confirmation_events"))
  -- Approval assessment is separate from the completed command's chat preview.
  eq({ { text = child.lua_get("command"), ft = "bash" }, { text = "done", ft = "text" } }, child.lua_get("result.summary.detail"))
end

T["synchronous numbered choices include the assessment preview"] = function()
  child.lua([[
    require("sia.config").options.settings.ui.confirm.async.enable = false
    start_bash()
  ]])
  local text = table.concat(child.lua_get("previews[1].lines"), "\n")
  eq(true, text:find("**Level:** medium", 1, true) ~= nil)
  eq(true, text:find("## Choices", 1, true) ~= nil)
  eq(true, text:find("Check the project workspace", 1, true) ~= nil)
  eq(0, child.lua_get("executions"))
  child.lua("answer('1')")
  eq(1, child.lua_get("executions"))
  eq(1, child.lua_get("cleared"))
end

T["external selection uses description and shows assessment alongside it"] = function()
  child.lua([[
    local confirm = require("sia.config").options.settings.ui.confirm
    confirm.async.enable = false
    confirm.use_vim_ui = true
    start_bash()
  ]])
  eq("Check the project workspace", child.lua_get("selection_prompt"))
  eq(true, table.concat(child.lua_get("previews[1].lines"), "\n"):find("**Level:** medium", 1, true) ~= nil)
  child.lua("choose(nil, 1)")
  eq(1, child.lua_get("executions"))
  eq(1, child.lua_get("cleared"))
end

T["malformed verifier response falls back without executing"] = function()
  child.lua("verifier_response = 'not json'; start_bash(); approval.on_preview()")
  eq("Run shell checks", child.lua_get("approval_prompt"))
  eq(0, child.lua_get("executions"))
  local text = table.concat(child.lua_get("previews[1].lines"), "\n")
  eq(nil, text:find("## Risk assessment", 1, true))
  eq(nil, text:find("Not assessed", 1, true))
  eq(true, text:find(child.lua_get("command"), 1, true) ~= nil)
end

T["trusted risk thresholds still auto approve without opening UI"] = function()
  child.lua("test_threshold = 'medium'; start_bash()")
  eq(1, child.lua_get("executions"))
  eq(0, child.lua_get("#previews"))
  eq(true, child.lua_get("approval == nil"))
  eq("medium", child.lua_get("result.verification.level"))
  eq({}, child.lua_get("confirmation_events"))
end

T["declining the approval never runs the command"] = function()
  child.lua("start_bash(); approval.on_cancel()")
  eq(0, child.lua_get("executions"))
  eq(true, child.lua_get("result.content:find('OPERATION DECLINED', 1, true) ~= nil"))
end

T["approval preview wraps visually without reformatting commands"] = function()
  child.lua([[
    -- Restore the real preview window for this rendering check.
    package.loaded["sia.preview"] = nil
    command = "printf '%s' '" .. string.rep("long value ", 20) .. "'"
    start_bash()
    approval.on_preview()
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    _G.real_preview = {
      lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
      wrap = vim.wo[win].wrap, linebreak = vim.wo[win].linebreak,
      ft = vim.bo[buf].filetype,
      height = vim.api.nvim_win_get_height(win),
      display_height = vim.api.nvim_win_text_height(win, {}).all,
      max_height = math.floor(vim.o.lines * 0.7),
    }
    require("sia.preview").clear()
  ]])
  local preview = child.lua_get("real_preview")
  eq(true, preview.wrap)
  eq(true, preview.linebreak)
  eq("markdown", preview.ft)
  eq(child.lua_get("command"), preview.lines[4])
  eq(math.min(preview.display_height, preview.max_height), preview.height)
end

T["external input fallback still shows the command preview"] = function()
  child.lua([[
    local confirm = require("sia.config").options.settings.ui.confirm
    confirm.async.enable = false
    confirm.use_vim_ui = true
    verifier_response = "invalid"
    start_bash()
  ]])
  eq(true, child.lua_get("input_prompt:find('Run shell checks', 1, true) ~= nil"))
  local text = table.concat(child.lua_get("previews[1].lines"), "\n")
  eq(nil, text:find("## Risk assessment", 1, true))
  eq(nil, text:find("Not assessed", 1, true))
  eq(true, text:find(child.lua_get("command"), 1, true) ~= nil)
  child.lua("answer(nil)")
  eq(0, child.lua_get("executions"))
  eq(1, child.lua_get("cleared"))
end

T["AI assessment stays quiet until it requests manual approval"] = function()
  child.lua([[
    require("sia.assistant").fetch_response = function(_, opts)
      _G.finish_assessment = opts.on_complete
    end
    start_bash()
  ]])
  eq({}, child.lua_get("confirmation_events"))
  eq(0, child.lua_get("executions"))
  child.lua("finish_assessment(vim.json.encode(test_verdict))")
  eq({ true }, child.lua_get("confirmation_events"))
  child.lua("approval.on_accept()")
  eq({ true, false }, child.lua_get("confirmation_events"))
end

return T
