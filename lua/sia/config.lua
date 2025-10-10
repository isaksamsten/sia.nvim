local providers = require("sia.provider")
local M = {}

--- @type table<string, {mtime: integer, json: table}?>
local config_cache = {}

local function validate_permission_patterns(patterns, path)
  if type(patterns) ~= "table" then
    return false, path .. " must be an array, got " .. type(patterns)
  end

  for i, pattern_def in ipairs(patterns) do
    local pattern

    if type(pattern_def) == "string" then
      pattern = pattern_def
    elseif type(pattern_def) == "table" then
      if type(pattern_def.pattern) ~= "string" then
        return false,
          path .. "[" .. i .. "].pattern must be a string, got " .. type(
            pattern_def.pattern
          )
      end

      if pattern_def.negate ~= nil and type(pattern_def.negate) ~= "boolean" then
        return false,
          path .. "[" .. i .. "].negate must be a boolean, got " .. type(
            pattern_def.negate
          )
      end

      pattern = pattern_def.pattern
    else
      return false,
        path
          .. "["
          .. i
          .. "] must be a string or object with 'pattern' field, got "
          .. type(pattern_def)
    end

    local ok, err = pcall(string.match, "test", pattern)
    if not ok then
      return false, "invalid regex pattern in " .. path .. "[" .. i .. "]: " .. err
    end
  end
  return true
end

local function validate_permissions(permission)
  if not permission then
    return true
  end

  if type(permission) ~= "table" then
    return false, "'permission' must be an object, got " .. type(permission)
  end

  for section_name, section in pairs(permission) do
    if type(section) ~= "table" then
      return false,
        "permission." .. section_name .. " must be an object, got " .. type(section)
    end

    for tool_name, tool_perms in pairs(section) do
      if type(tool_perms) ~= "table" then
        return false,
          "permission."
            .. section_name
            .. "."
            .. tool_name
            .. " must be an object, got "
            .. type(tool_perms)
      end

      if not tool_perms.arguments then
        return false,
          "permission."
            .. section_name
            .. "."
            .. tool_name
            .. " must have an 'arguments' field"
      end

      if type(tool_perms.arguments) ~= "table" then
        return false,
          "permission."
            .. section_name
            .. "."
            .. tool_name
            .. ".arguments must be an object, got "
            .. type(tool_perms.arguments)
      end

      for param_name, patterns in pairs(tool_perms.arguments) do
        local path = "permission."
          .. section_name
          .. "."
          .. tool_name
          .. ".arguments."
          .. param_name
        local ok, err = validate_permission_patterns(patterns, path)
        if not ok then
          return false, err
        end
      end

      if section_name == "allow" and tool_perms.choice ~= nil then
        if
          type(tool_perms.choice) ~= "number"
          or tool_perms.choice < 1
          or tool_perms.choice ~= math.floor(tool_perms.choice)
        then
          return false,
            "permission."
              .. section_name
              .. "."
              .. tool_name
              .. ".choice must be a positive integer, got "
              .. type(tool_perms.choice)
        end
      end
    end
  end
  return true
end

local function validate_context(context)
  if not context then
    return true
  end

  if type(context) ~= "table" then
    return false, "'context' must be an object, got " .. type(context)
  end

  if context.max_tool ~= nil then
    if
      type(context.max_tool) ~= "number"
      or context.max_tool < 0
      or context.max_tool ~= math.floor(context.max_tool)
    then
      return false,
        "context.max_tool must be a non-negative integer, got " .. type(
          context.max_tool
        )
    end
  end

  if context.exclude ~= nil then
    if type(context.exclude) ~= "table" then
      return false, "context.exclude must be an array, got " .. type(context.exclude)
    end

    for i, item in ipairs(context.exclude) do
      if type(item) ~= "string" then
        return false,
          "context.exclude[" .. i .. "] must be a string, got " .. type(item)
      end
    end
  end

  if context.clear_input ~= nil then
    if type(context.clear_input) ~= "boolean" then
      return false,
        "context.clear_input must be a boolean, got " .. type(context.clear_input)
    end
  end

  if context.keep ~= nil then
    if
      type(context.keep) ~= "number"
      or context.keep < 0
      or context.keep ~= math.floor(context.keep)
    then
      return false,
        "context.keep must be a non-negative integer, got " .. type(context.keep)
    end
  end

  return true
end

local function validate_action(action)
  if not action then
    return true
  end

  if type(action) ~= "table" then
    return false, "'action' must be an object, got " .. type(action)
  end

  local allowed_fields = { insert = true, diff = true, chat = true }
  for field, value in pairs(action) do
    if allowed_fields[field] and type(value) ~= "string" then
      return false,
        string.format("action.%s must be a string, got %s", field, type(value))
    end

    if not M.options.actions[value] then
      return false, string.format("action.%s, %s is no a defined action", field, value)
    end
  end

  return true
end

local function validate_model_field(json, field)
  if json[field] ~= nil then
    if type(json[field]) ~= "string" then
      return false,
        string.format("'%s' must be a string, got %s", field, type(json[field]))
    elseif not M.options.models[json[field]] then
      return false,
        string.format(
          "'%s' must be one of the allowed models, got '%s'",
          field,
          tostring(json[field])
        )
    end
  end
  return true
end

--- @class sia.LocalConfig
--- @field action { insert: string?, diff: string?, chat: string?}?
--- @field auto_continue boolean?
--- @field model string?
--- @field fast_model string?
--- @field plan_model string?
--- @field permission { deny: table?, allow: table?, ask: table?}?
--- @field context sia.config.Context?

--- @return sia.LocalConfig?
function M.get_local_config()
  local root = vim.fs.root(0, ".sia")
  if not root then
    return nil
  end

  local local_config = vim.fs.joinpath(root, ".sia", "config.json")
  local stat = vim.uv.fs_stat(local_config)
  if not stat then
    return nil
  end

  local cache = config_cache[root]
  if cache and stat.mtime.sec == cache.mtime then
    return cache.json
  end

  local read_ok, file_content = pcall(vim.fn.readfile, local_config)
  if not read_ok then
    vim.notify(
      string.format(
        "Sia: Failed to read config file %s: %s",
        local_config,
        file_content
      ),
      vim.log.levels.ERROR
    )
    return nil
  end

  local has_failed = false
  local function validate(fun, ...)
    if not has_failed then
      local ok, err = fun(...)
      if not ok then
        vim.notify(
          string.format("Sia: Config file %s: %s", local_config, err),
          vim.log.levels.ERROR
        )
        has_failed = true
      end
    end
  end
  local content = table.concat(file_content, " ")
  local decode_ok, json = pcall(vim.json.decode, content)
  if not decode_ok then
    vim.notify(
      string.format("Sia: Invalid JSON in config file %s: %s", local_config, json),
      vim.log.levels.ERROR
    )
    has_failed = true
  end

  if not has_failed and type(json) ~= "table" then
    vim.notify(
      string.format(
        "Sia: Config file %s must contain a JSON object, got %s",
        local_config,
        type(json)
      ),
      vim.log.levels.ERROR
    )
    has_failed = true
  end

  validate(validate_permissions, json.permission)
  validate(validate_context, json.context)
  validate(validate_action, json.action)
  validate(validate_model_field, json, "model")
  validate(validate_model_field, json, "fast_model")
  validate(validate_model_field, json, "plan_model")
  validate(function()
    if json.auto_continue and type(json.auto_continue) ~= "boolean" then
      return false,
        string.format(
          "'%s' must be a boolean, got %s",
          json.auto_continue,
          type(json.auto_continue)
        )
    end
    return true
  end)

  config_cache[root] = { mtime = stat.mtime.sec, json = not has_failed and json or nil }
  return json
end

--- @param type ("model"|"fast_model"|"plan_model")?
--- @return string
function M.get_default_model(type)
  local lc = M.get_local_config() or {}
  type = type or "model"
  return lc[type] or M.options.defaults[type]
end

--- @return sia.config.Context
function M.get_context_config()
  local local_config = M.get_local_config()
  if local_config and local_config.context then
    return vim.tbl_deep_extend(
      "keep",
      local_config.context or {},
      M.options.defaults.context or {}
    )
  end
  return M.options.defaults.context or {}
end

--- @param mode "insert"|"diff"|"chat"|"hidden"
--- @return sia.config.Action
function M.get_default_action(mode)
  local lc = M.get_local_config()
  return lc and lc.action and M.options.actions[lc.action[mode]]
    or M.options.defaults.actions[mode]
end

--- @alias sia.config.Role "user"|"system"|"assistant"|"tool"
--- @alias sia.config.Placement ["below"|"above", "start"|"end"|"cursor"]|"start"|"end"|"cursor"
--- @alias sia.config.ActionInput "require"|"ignore"
--- @alias sia.config.ActionMode "chat"|"diff"|"insert"|"hidden"

--- @class sia.config.Insert
--- @field placement (fun():sia.config.Placement)|sia.config.Placement
--- @field cursor ("start"|"end")?
--- @field message [string, string]?

--- @class sia.config.Diff
--- @field wo [string]?
--- @field cmd string?

--- @class sia.config.Chat
--- @field cmd string?
--- @field wo table<string, any>?

--- @class sia.config.Hidden
--- @field callback (fun(ctx:sia.Context?, content:string[]):nil)?
--- @field messages { on_start: string?, on_progress: string[]? }?

--- @class sia.config.Instruction
--- @field role sia.config.Role
--- @field hide boolean?
--- @field description ((fun(ctx:sia.Context?):string)|string)?
--- @field content ((fun(ctx: sia.Context?):string?)|string|string[]|sia.InstructionContent[])?
--- @field kind string?
--- @field live_content (fun():string?)?
--- @field tool_calls sia.ToolCall[]?
--- @field _tool_call sia.ToolCall?

--- @alias sia.config.ToolExecute fun(arguments: table, conversation: sia.Conversation, callback: fun(opts: sia.ToolResult?), cancellable: sia.Cancellable?)
--- @class sia.config.Tool
--- @field name string
--- @field description string
--- @field system_prompt string?
--- @field allow_parallel (fun(conv: sia.Conversation, args: table):boolean)?
--- @field message string|(fun(args:table):string)?
--- @field parameters table<string, sia.ToolParameter>
--- @field is_available (fun():boolean)?
--- @field required string[]?
--- @field execute sia.config.ToolExecute

--- @class sia.config.Action
--- @field system (string|sia.config.Instruction)[]?
--- @field instructions (string|sia.config.Instruction)[]
--- @field modify_instructions (fun(instructions:(string|sia.config.Instruction|(fun():sia.config.Instruction[]))[], ctx: sia.ActionContext):nil)?
--- @field tools (sia.config.Tool|string)[]?
--- @field ignore_tool_confirm boolean?
--- @field model string?
--- @field temperature number?
--- @field input sia.config.ActionInput?
--- @field mode sia.config.ActionMode?
--- @field enabled (fun():boolean)|boolean?
--- @field capture nil|(fun(arg: sia.ActionContext):[number, number])
--- @field range boolean?
--- @field insert sia.config.Insert?
--- @field diff sia.config.Diff?
--- @field chat sia.config.Chat?
--- @field hidden sia.config.Hidden?

--- @class sia.config.Context
--- @field max_tool integer?
--- @field exclude string[]?
--- @field clear_input boolean?
--- @field keep integer?

--- @class sia.config.Defaults
--- @field model string
--- @field fast_model string
--- @field plan_model string
--- @field temperature number
--- @field context sia.config.Context?
--- @field actions table<"diff"|"chat"|"insert", sia.config.Action>
--- @field chat sia.config.Chat
--- @field diff sia.config.Diff
--- @field insert sia.config.Insert
--- @field hidden sia.config.Hidden
--- @field tools { enable: boolean, choices: table<string, sia.config.Tool[]?>}
--- @field file_ops {trash: boolean?, restrict_to_project_root: boolean?, create_dirs_on_rename: boolean?}?
--- @field ui {use_vim_ui: boolean?, show_signs: boolean?, char_diff: boolean?, show_preview:boolean?}?

--- @alias sia.config.Models table<string, [string, string]>

--- @class sia.config.Provider
--- @field base_url string
--- @field api_key fun():string?
--- @field format_messages (fun(model:string, prompt:sia.Prompt[]):nil)?

--- @class sia.config.Options
--- @field models sia.config.Models
--- @field instructions table<string, sia.config.Instruction|sia.config.Instruction[]>
--- @field defaults sia.config.Defaults
--- @field actions table<string, sia.config.Action>
--- @field providers table<string, sia.config.Provider>
M.options = {
  providers = {
    openai = providers.openai,
    copilot = providers.copilot,
    gemini = providers.gemini,
    anthropic = providers.anthropic,
    ollama = providers.ollama(11434),
    shimmy = providers.ollama(11435),
    openrouter = providers.openrouter,
    zai = providers.zai_coding,
  },
  models = {
    ["zai/glm-4.5"] = { "zai", "GLM-4.5" },
    ["zai/glm-4.6"] = { "zai", "GLM-4.6" },
    ["openai/gpt-5"] = { "openai", "gpt-5", temperature = 1 },
    ["openai/gpt-4.1"] = { "openai", "gpt-4.1" },
    ["openai/gpt-4.1-mini"] = { "openai", "gpt-4.1-mini" },
    ["openai/gpt-4.1-nano"] = { "openai", "gpt-4.1-nano" },
    ["openai/gpt-4o"] = { "openai", "gpt-4o" },
    ["openai/gpt-4o-mini"] = { "openai", "gpt-4o-mini" },
    ["openai/o3"] = { "openai", "o3", reasoning_effort = "medium" },
    ["openai/o4-mini"] = { "openai", "o4-mini", reasoning_effort = "medium" },
    ["openai/o3-mini"] = { "openai", "o3-mini", reasoning_effort = "medium" },
    ["openai/o3-mini-low"] = { "openai", "o3-mini", reasoning_effort = "low" },
    ["openai/o3-mini-high"] = { "openai", "o3-mini", reasoning_effort = "high" },
    ["openai/chatgpt-4o-latest"] = { "openai", "chatgpt-4o-latest" },
    ["copilot/gpt-4o"] = { "copilot", "gpt-4o" },
    ["copilot/gpt-4.1"] = { "copilot", "gpt-4.1" },
    ["copilot/gpt-5"] = { "copilot", "gpt-5" },
    ["copilot/gpt-5-mini"] = { "copilot", "gpt-5-mini" },
    ["copilot/gpt-4.1-mini"] = { "copilot", "gpt-4.1-mini" },
    ["copilot/gpt-4.1-nano"] = { "copilot", "gpt-4.1-nano" },
    ["copilot/o3"] = { "copilot", "o3", reasoning_effort = "medium" },
    ["copilot/o4-mini"] = { "copilot", "o4-mini", reasoning_effort = "medium" },
    ["copilot/claude-sonnet-3.7"] = { "copilot", "claude-3.7-sonnet" },
    ["copilot/claude-sonnet-4"] = { "copilot", "claude-sonnet-4" },
    ["copilot/claude-sonnet-4.5"] = { "copilot", "claude-sonnet-4.5" },
    ["copilot/o3-mini"] = { "copilot", "o3-mini", reasoning_effort = "medium" },
    ["copilot/grok-code-fast-1"] = { "copilot", "grok-code-fast-1" },
    ["gemini/1.5-flash-8b"] = { "gemini", "gemini-1.5-flash-8b" },
    ["gemini/1.5-flash"] = { "gemini", "gemini-1.5-flash" },
    ["gemini/2.0-flash-exp"] = { "gemini", "gemini-2.0-flash-exp" },
    ["gemini/1.5-pro"] = { "gemini", "gemini-1.5-pro" },
    ["gemini/2.5-pro"] = { "gemini", "gemini-2.5-pro-exp-03-25" },
    ["anthropic/claude-sonnet-4"] = { "anthropic", "claude-4-sonnet-20250514" },
    ["anthropic/claude-sonnet-3.7"] = { "anthropic", "claude-3-7-sonnet-latest" },
    ["openrouter/claude-sonnet-4"] = { "openrouter", "anthropic/claude-sonnet-4" },
    ["openrouter/gemini-2.5-pro"] = { "openrouter", "google/gemini-2.5-pro" },
    ["openrouter/glm-4.5"] = { "openrouter", "z-ai/glm-4.5" },
    ["openrouter/qwen3-coder"] = { "openrouter", "qwen/qwen3-coder" },
    ["openrouter/kimi-k2"] = { "openrouter", "moonshotai/kimi-k2" },
    ["openrouter/gpt-5"] = { "openrouter", "openai/gpt-5" },
    ["openrouter/gpt-5-codex"] = { "openrouter", "openai/gpt-5-codex" },
    ["openrouter/gpt-5-mini"] = { "openrouter", "openai/gpt-5-mini" },
    ["openrouter/grok-code-fast-1"] = { "openrouter", "x-ai/grok-code-fast-1" },
    ["openrouter/qwen3-next"] = { "openrouter", "qwen/qwen3-next-80b-a3b-instruct" },
  },
  instructions = {},
  --- @type sia.config.Defaults
  defaults = {
    model = "openai/gpt-4.1",
    fast_model = "openai/gpt-4.1-mini",
    plan_model = "openai/o3-mini",
    temperature = 0.3, -- default temperature
    context = nil,
    chat = {
      cmd = "botright vnew",
      wo = { wrap = true },
    },
    hidden = {
      messages = {},
    },
    diff = {
      cmd = "vnew",
      wo = { "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak" },
    },
    insert = {
      placement = "cursor",
    },
    file_ops = {
      trash = true,
      create_dirs_on_rename = true,
      restrict_to_project_root = true,
    },
    ui = {
      use_vim_ui = false,
      show_signs = true,
      char_diff = true,
      show_preview = true, -- only if use_vim_ui is false
    },
    tools = {
      enable = true,
      choices = {
        locations = require("sia.tools").locations,
        read = require("sia.tools").read,
        edit = require("sia.tools").edit,
        insert = require("sia.tools").insert,
        write = require("sia.tools").write,
        glob = require("sia.tools").glob,
        diagnostics = require("sia.tools").diagnostics,
        grep = require("sia.tools").grep,
        agent = require("sia.tools").agent,
        plan = require("sia.tools").plan,
        compact = require("sia.tools").compact,
        workspace = require("sia.tools").workspace,
        rename = require("sia.tools").rename,
        remove = require("sia.tools").remove,
        bash = require("sia.tools").bash,
        fetch = require("sia.tools").fetch,
        websearch = require("sia.tools").websearch,
      },
    },
    actions = {
      insert = {
        mode = "insert",
        input = "require",
        temperature = 0.2,
        system = { "insert_system" },
        instructions = {
          require("sia.instructions").current_buffer({
            show_line_numbers = true,
            include_cursor = true,
          }),
        },
      },
      diff = {
        mode = "diff",
        input = "require",
        temperature = 0.2,
        system = { "diff_system" },
        instructions = {
          require("sia.instructions").current_buffer({
            show_line_numbers = true,
            include_cursor = true,
          }),
          require("sia.instructions").current_context({
            show_line_numbers = true,
            fences = false,
          }),
        },
      },
      --- @type sia.config.Action
      chat = {
        mode = "chat",
        temperature = 0.1,
        system = {
          "default_system",
          "system_info",
          "directory_structure",
          "agents_md",
        },
        instructions = {
          "visible_buffers",
          "current_context",
        },
        tools = {
          "grep",
          "workspace",
          "locations",
          "edit",
          "write",
          "insert",
          "read",
          "glob",
          "diagnostics",
          "rename",
          "remove",
          "bash",
          "fetch",
          "websearch",
        },
      },
    },
  },
  actions = {
    --- @type sia.config.Action
    prose = {
      mode = "chat",
      temperature = 0.3,
      system = {
        "prose_system",
        "system_info",
        "directory_structure",
        "agents_md",
      },
      instructions = {
        "visible_buffers",
        "current_context",
      },
      tools = {
        "workspace",
        "locations",
        "edit",
        "write",
        "read",
        "glob",
        "grep",
        "rename",
        "remove",
        "fetch",
        "websearch",
      },
    },
    commit = require("sia.actions").commit(),
    doc = require("sia.actions").doc(),
  },
}

function M.setup(options)
  M.options = vim.tbl_deep_extend("force", {}, M.options, options or {})
end

return M
