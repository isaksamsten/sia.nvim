local anthropic = require("sia.provider.anthropic")
local common = require("sia.provider.common")
local utils = require("sia.utils")

local M = {}

local TOOL_PREFIX = "mcp_"
local SYSTEM_PREFIX = "You are Claude Code, Anthropic's official CLI for Claude."
local DEFAULT_BETAS = {
  "claude-code-20250219",
  "oauth-2025-04-20",
  "interleaved-thinking-2025-05-14",
  "prompt-caching-scope-2026-01-05",
  "context-management-2025-06-27",
}
local BILLING_SALT = "59cf53e54c78"
local DEFAULT_CLI_VERSION = "2.1.90"
local DEFAULT_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
local DEFAULT_AUTH_URL = "https://claude.ai/oauth/authorize"
local DEFAULT_TOKEN_URL = "https://console.anthropic.com/v1/oauth/token"
local DEFAULT_REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback"
local DEFAULT_SCOPE = "org:create_api_key user:profile user:inference"
local REFRESH_SKEW_MS = 60000

local browser_token = nil
local force_refresh = false
local session_id = utils.new_uuid()

---@param name string
---@return string?
local function env(name)
  local value = os.getenv(name)
  if not value or value == "" then
    return nil
  end
  return vim.trim(value)
end

---@return string
local function get_cache_dir()
  local cache_dir = vim.fn.stdpath("cache") .. "/sia"
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end
  return cache_dir
end

---@param path string
---@return table?
local function load_json(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), ""))
  end)
  if ok and type(data) == "table" then
    return data
  end
  return nil
end

---@param path string
---@param data table
local function save_json(path, data)
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

---@return string
local function get_browser_token_path()
  return get_cache_dir() .. "/claudecode_oauth.json"
end

---@return string
local function get_user_agent()
  return env("CLAUDE_CODE_AUTH_USER_AGENT") or "claude-cli/2.1.2 (external, cli)"
end

---@return string
local function get_cli_version()
  return env("ANTHROPIC_CLI_VERSION") or DEFAULT_CLI_VERSION
end

---@return string
local function get_entrypoint()
  return env("CLAUDE_CODE_ENTRYPOINT") or "cli"
end

---@return string[]
local function get_betas()
  local value = env("CLAUDE_CODE_AUTH_BETAS")
  if not value then
    return vim.deepcopy(DEFAULT_BETAS)
  end
  return vim
    .iter(vim.split(value, ",", { plain = true }))
    :map(vim.trim)
    :filter(function(item)
      return item ~= ""
    end)
    :totable()
end

---@return string
local function get_client_id()
  return env("ANTHROPIC_CLIENT_ID") or DEFAULT_CLIENT_ID
end

---@return string
local function get_auth_url()
  return env("ANTHROPIC_AUTH_URL") or DEFAULT_AUTH_URL
end

---@return string
local function get_token_url()
  return env("ANTHROPIC_TOKEN_URL") or DEFAULT_TOKEN_URL
end

---@return string
local function get_redirect_uri()
  return env("ANTHROPIC_REDIRECT_URI") or DEFAULT_REDIRECT_URI
end

---@return string
local function get_scope()
  return env("ANTHROPIC_SCOPE") or DEFAULT_SCOPE
end

---@param model_id string
---@return table?
local function get_model_override(model_id)
  local lower = model_id:lower()
  if lower:find("haiku", 1, true) then
    return {
      exclude = { ["interleaved-thinking-2025-05-14"] = true },
      disable_effort = true,
    }
  end
  if
    lower:find("4-6", 1, true)
    or lower:find("4.6", 1, true)
    or lower:find("4-7", 1, true)
  then
    return {
      add = { "effort-2025-11-24" },
    }
  end
  return nil
end

---@param expires integer
---@return boolean
local function is_fresh(expires)
  return expires > ((os.time() * 1000) + REFRESH_SKEW_MS)
end

---@param raw string
---@return string
local function base64url_encode(raw)
  return (vim.base64.encode(raw):gsub("+", "-"):gsub("/", "_"):gsub("=+$", ""))
end

---@param length integer
---@return string
local function random_bytes(length)
  local f = io.open("/dev/urandom", "rb")
  if f then
    local raw = f:read(length)
    f:close()
    if raw and #raw == length then
      return raw
    end
  end

  math.randomseed(os.time() + vim.uv.hrtime())
  local bytes = {}
  for i = 1, length do
    bytes[i] = string.char(math.random(0, 255))
  end
  return table.concat(bytes)
end

---@param value string
---@return string
local function sha256_base64url(value)
  local hash = vim.fn.system(
    string.format(
      "printf '%%s' %s | openssl dgst -sha256 -binary",
      vim.fn.shellescape(value)
    )
  )
  return base64url_encode(hash)
end

---@param value string
---@return string
local function sha256_hex(value)
  local hash = vim.fn.system(
    string.format(
      "printf '%%s' %s | openssl dgst -sha256 -hex",
      vim.fn.shellescape(value)
    )
  )
  local hex = hash:match("= (%x+)")
  return hex or ""
end

---@return table?
local function load_browser_token()
  local data = load_json(get_browser_token_path())
  if data and type(data.expires) == "number" then
    return data
  end
  return nil
end

---@param creds table
local function save_browser_token(creds)
  browser_token = creds
  save_json(get_browser_token_path(), creds)
end

---@param params table<string, string>
---@return table?, string?
local function token_request(params)
  local body = {}
  for key, value in pairs(params) do
    table.insert(body, key .. "=" .. vim.uri_encode(value))
  end

  local raw = vim.fn.system({
    "curl",
    "--silent",
    "--request",
    "POST",
    "--header",
    "content-type: application/x-www-form-urlencoded",
    "--header",
    "user-agent: " .. get_user_agent(),
    "--data",
    table.concat(body, "&"),
    get_token_url(),
  })
  if vim.v.shell_error ~= 0 then
    return nil, "Anthropic token request failed"
  end

  local ok, json = pcall(vim.json.decode, raw)
  if not ok or type(json) ~= "table" then
    return nil, "Anthropic token response could not be parsed"
  end

  if json.error then
    if type(json.error) == "string" then
      return nil, json.error
    end
    if type(json.error.message) == "string" then
      return nil, json.error.message
    end
    return nil, "Anthropic token request failed"
  end

  if
    type(json.access_token) ~= "string"
    or type(json.refresh_token) ~= "string"
    or type(json.expires_in) ~= "number"
  then
    return nil, "Anthropic token response is missing required fields"
  end

  return {
    access = json.access_token,
    refresh = json.refresh_token,
    expires = (os.time() * 1000) + (json.expires_in * 1000),
  }
end

---@return table
local function start_browser_oauth()
  local verifier = base64url_encode(random_bytes(32))
  local state = base64url_encode(random_bytes(24))
  local params = {
    "code=true",
    "client_id=" .. vim.uri_encode(get_client_id()),
    "response_type=code",
    "redirect_uri=" .. vim.uri_encode(get_redirect_uri()),
    "scope=" .. vim.uri_encode(get_scope()),
    "code_challenge=" .. vim.uri_encode(sha256_base64url(verifier)),
    "code_challenge_method=S256",
    "state=" .. vim.uri_encode(state),
  }

  return {
    verifier = verifier,
    state = state,
    url = get_auth_url() .. "?" .. table.concat(params, "&"),
  }
end

---@param text string
---@return string?, string?
local function parse_auth_code(text)
  local value = vim.trim(text)
  if value == "" then
    return nil, "Authorization code required"
  end

  local code, state = value:match("^([^#]+)#(.+)$")
  if code then
    return code, state
  end

  return value, nil
end

---@param text string
---@param state string
---@param verifier string
---@return table?, string?
local function exchange_auth_code(text, state, verifier)
  local code, returned_state = parse_auth_code(text)
  if not code then
    return nil, returned_state
  end
  if returned_state and returned_state ~= state then
    return nil, "Authorization state mismatch"
  end

  return token_request({
    code = code,
    state = state,
    grant_type = "authorization_code",
    client_id = get_client_id(),
    redirect_uri = get_redirect_uri(),
    code_verifier = verifier,
  })
end

---@param refresh_token string
---@return table?, string?
local function refresh_browser_token(refresh_token)
  return token_request({
    grant_type = "refresh_token",
    refresh_token = refresh_token,
    client_id = get_client_id(),
  })
end

---@param force boolean?
---@return table?, string?
local function ensure_browser_token(force)
  if not force and browser_token and is_fresh(browser_token.expires) then
    return browser_token
  end

  browser_token = load_browser_token()
  if not browser_token then
    return nil, "browser oauth not authorized"
  end

  if force or not is_fresh(browser_token.expires) then
    local refreshed, err = refresh_browser_token(browser_token.refresh)
    if not refreshed then
      return nil, err
    end
    save_browser_token(refreshed)
    browser_token = refreshed
  end

  return browser_token
end

---@param force boolean?
---@return string?, string?
local function get_access_token(force)
  local creds, err = ensure_browser_token(force)
  if creds then
    return creds.access
  end
  return nil, err or "run :SiaAuth claudecode to authorize"
end

---@param name string
---@return string
local function prefix_tool_name(name)
  if vim.startswith(name, TOOL_PREFIX) then
    return name
  end
  return TOOL_PREFIX .. name:sub(1, 1):upper() .. name:sub(2)
end

---@param name string
---@return string
local function unprefix_tool_name(name)
  local stripped = name:gsub("^" .. TOOL_PREFIX, "")
  return stripped:sub(1, 1):lower() .. stripped:sub(2)
end

---@param input string
---@return string
local function rewrite_text(input)
  return (
    input
      :gsub("OpenCode", "Claude Code")
      :gsub("opencode", "Claude")
      :gsub("Sia", "Claude Code")
      :gsub("sia", "Claude")
  )
end

---@param text string
---@return string
local function compute_cch(text)
  return sha256_hex(text):sub(1, 5)
end

---@param text string
---@param version string
---@return string
local function compute_version_suffix(text, version)
  local chars = {}
  for _, idx in ipairs({ 5, 8, 21 }) do
    chars[#chars + 1] = idx <= #text and text:sub(idx, idx) or "0"
  end
  return sha256_hex(BILLING_SALT .. table.concat(chars) .. version):sub(1, 3)
end

---@param messages table[]
---@return string
local function extract_first_user_text(messages)
  for _, message in ipairs(messages) do
    if message.role == "user" then
      if type(message.content) == "string" then
        return message.content
      end
      if type(message.content) == "table" then
        for _, block in ipairs(message.content) do
          if block.type == "text" and type(block.text) == "string" then
            return block.text
          end
        end
      end
      return ""
    end
  end
  return ""
end

---@param messages table[]
---@return string
local function build_billing_header(messages)
  local first_user_text = extract_first_user_text(messages)
  local version = get_cli_version()
  return string.format(
    "x-anthropic-billing-header: cc_version=%s.%s; cc_entrypoint=%s; cch=%s;",
    version,
    compute_version_suffix(first_user_text, version),
    get_entrypoint(),
    compute_cch(first_user_text)
  )
end

---@param messages table[]
---@param prefix string
local function prepend_system_to_first_user(messages, prefix)
  for _, message in ipairs(messages) do
    if message.role == "user" then
      if type(message.content) == "string" then
        message.content = prefix .. "\n\n" .. message.content
      elseif type(message.content) == "table" then
        table.insert(message.content, 1, { type = "text", text = prefix })
      end
      return
    end
  end
end

---@param data table
---@param model_id string
local function apply_model_workarounds(data, model_id)
  local override = get_model_override(model_id)
  if not override then
    return
  end

  if override.disable_effort then
    if type(data.output_config) == "table" then
      data.output_config.effort = nil
      if vim.tbl_isempty(data.output_config) then
        data.output_config = nil
      end
    end
    if type(data.thinking) == "table" then
      data.thinking.effort = nil
      if vim.tbl_isempty(data.thinking) then
        data.thinking = nil
      end
    end
  end
end

---@param model_id string
---@return string[]
local function get_model_betas(model_id)
  local betas = get_betas()
  local override = get_model_override(model_id)
  if override and override.exclude then
    betas = vim
      .iter(betas)
      :filter(function(beta)
        return not override.exclude[beta]
      end)
      :totable()
  end
  if override and override.add then
    for _, beta in ipairs(override.add) do
      if not vim.tbl_contains(betas, beta) then
        table.insert(betas, beta)
      end
    end
  end
  return betas
end

---@param model_id string
---@return string[]
local function build_oauth_headers(model_id)
  local token, err = get_access_token(force_refresh)
  force_refresh = false
  if not token then
    vim.notify(
      "sia: Claude Code auth unavailable: " .. (err or "unknown error"),
      vim.log.levels.WARN
    )
    return {}
  end

  return {
    "--header",
    "anthropic-version: 2023-06-01",
    "--header",
    "authorization: Bearer " .. token,
    "--header",
    "anthropic-beta: " .. table.concat(get_model_betas(model_id), ","),
    "--header",
    "x-app: cli",
    "--header",
    "x-client-request-id: " .. utils.new_uuid(),
    "--header",
    "X-Claude-Code-Session-Id: " .. session_id,
    "--header",
    "user-agent: " .. get_user_agent(),
  }
end

---@type sia.Provider
local messages = vim.deepcopy(anthropic.messages)
messages.chat_endpoint = "v1/messages?beta=true"
messages.api_key = function()
  local token, err = get_access_token(force_refresh)
  force_refresh = false
  if not token then
    vim.notify(
      "sia: Claude Code auth unavailable: " .. (err or "run :SiaAuth claudecode"),
      vim.log.levels.WARN
    )
    return nil
  end
  return token
end
messages.prepare_tools = function(data, tools)
  if not tools then
    return
  end

  data.tools = vim
    .iter(tools)
    :filter(function(tool)
      return tool.type == "function"
    end)
    :map(function(tool)
      return {
        name = prefix_tool_name(tool.name),
        description = tool.description,
        input_schema = {
          type = "object",
          properties = tool.parameters,
          required = tool.required,
          additionalProperties = false,
        },
      }
    end)
    :totable()
end
messages.prepare_messages = function(data, model_id, messages_in)
  local moved_system = {}
  local conversation_messages = {}

  for _, message in ipairs(messages_in) do
    if message.role == "system" then
      if type(message.content) == "string" then
        table.insert(moved_system, rewrite_text(message.content))
      end
    elseif message.role == "tool" then
      table.insert(conversation_messages, {
        role = "user",
        content = {
          {
            type = "tool_result",
            tool_use_id = message.tool_call.id,
            content = message.content,
          },
        },
      })
    elseif message.role == "assistant" and message.tool_call then
      local content = {}

      -- Preserve thinking blocks (with signatures) before tool_use so the
      -- API accepts the round-trip when extended thinking is enabled.
      local reasoning_blocks = anthropic.reasoning_to_blocks(message.reasoning)
      if reasoning_blocks then
        for _, blk in ipairs(reasoning_blocks) do
          table.insert(content, blk)
        end
      end

      if message.content and message.content ~= "" then
        table.insert(content, { type = "text", text = message.content })
      end

      local input
      local arguments = message.tool_call.arguments
      if arguments ~= "" then
        local ok, decoded = pcall(vim.json.decode, arguments)
        if ok and type(decoded) == "table" then
          input = decoded
        end
      end

      table.insert(content, {
        type = "tool_use",
        id = message.tool_call.id,
        name = prefix_tool_name(message.tool_call.name),
        input = input or vim.empty_dict(),
      })
      table.insert(conversation_messages, {
        role = "assistant",
        content = content,
      })
    elseif message.role == "assistant" then
      local content = {}
      local reasoning_blocks = anthropic.reasoning_to_blocks(message.reasoning)
      if reasoning_blocks then
        for _, blk in ipairs(reasoning_blocks) do
          table.insert(content, blk)
        end
      end

      if type(message.content) == "table" then
        for _, part in ipairs(message.content) do
          table.insert(content, part)
        end
      elseif message.content and message.content ~= "" then
        table.insert(content, { type = "text", text = message.content })
      end

      if #content == 0 then
        -- empty assistant turn — skip
      elseif #content == 1 and not reasoning_blocks then
        table.insert(conversation_messages, {
          role = "assistant",
          content = content[1].type == "text" and content[1].text or content,
        })
      else
        table.insert(conversation_messages, {
          role = "assistant",
          content = content,
        })
      end
    else
      table.insert(conversation_messages, {
        role = message.role,
        content = message.content,
      })
    end
  end

  data.messages = common.merge_consecutive_messages(conversation_messages, {
    text_part_type = "text",
  })

  if #moved_system > 0 then
    prepend_system_to_first_user(data.messages, table.concat(moved_system, "\n\n"))
  end

  data.system = {
    { type = "text", text = build_billing_header(data.messages) },
    { type = "text", text = SYSTEM_PREFIX, cache_control = { type = "ephemeral" } },
  }

  apply_model_workarounds(data, type(model_id) == "string" and model_id or "")
  common.apply_prompt_caching(data.messages)
end
messages.get_headers = function(model, _, _)
  return build_oauth_headers(model.api_name or "")
end
messages.get_stats = function(callback, _)
  callback({})
end

local base_new_stream = messages.new_stream
messages.new_stream = function(strategy)
  local stream = base_new_stream(strategy)
  local base_process = stream.process_stream_chunk
  function stream:process_stream_chunk(obj)
    if
      obj.type == "content_block_start"
      and obj.content_block
      and obj.content_block.type == "tool_use"
    then
      obj = vim.deepcopy(obj)
      obj.content_block.name = unprefix_tool_name(obj.content_block.name)
    end
    return base_process(self, obj)
  end
  return stream
end
messages.on_http_error = function(code)
  if code == 401 or code == 403 then
    force_refresh = true
    return true
  end
  return false
end

---@param callback fun(entries: table<string, sia.provider.ModelSpec>?, err: string?)
local function discover(callback)
  local token, err = get_access_token(false)
  if not token then
    callback(
      nil,
      "Claude Code not authorized (" .. (err or "run :SiaAuth claudecode") .. ")"
    )
    return
  end

  local cmd = { "curl", "--silent" }
  vim.list_extend(cmd, build_oauth_headers(""))
  table.insert(cmd, "https://api.anthropic.com/v1/models")

  vim.system(
    cmd,
    { text = true },
    vim.schedule_wrap(function(response)
      if response.code ~= 0 then
        callback(nil, "curl failed with code " .. response.code)
        return
      end

      local ok, json = pcall(vim.json.decode, response.stdout)
      if not ok or type(json) ~= "table" then
        callback(nil, "JSON decode failed")
        return
      end

      if json.error then
        local msg = json.error.message or vim.inspect(json.error)
        callback(nil, msg)
        return
      end

      if not vim.islist(json.data) then
        callback(nil, "unexpected response format")
        return
      end

      local entries = {}
      for _, model in ipairs(json.data) do
        if type(model.id) == "string" then
          entries[model.id] = { api_name = model.id }
        end
      end
      callback(entries)
    end)
  )
end

---@param url string
local function open_url(url)
  local open_cmd = nil
  if vim.fn.has("mac") == 1 then
    open_cmd = "open"
  elseif vim.fn.has("unix") == 1 then
    open_cmd = "xdg-open"
  elseif vim.fn.has("win32") == 1 then
    open_cmd = "start"
  end

  if open_cmd and vim.fn.executable(open_cmd) == 1 then
    vim.fn.jobstart({ open_cmd, url }, { detach = true })
  else
    vim.notify("sia: open this URL to authorize:\n" .. url, vim.log.levels.INFO)
  end
end

---@param callback fun(data: any?)
local function authorize(callback)
  local oauth = start_browser_oauth()
  open_url(oauth.url)
  vim.notify(
    "sia: sign in in your browser, then paste the full code (or code#state) here.",
    vim.log.levels.INFO
  )

  vim.ui.input({ prompt = "Claude auth code: " }, function(input)
    if not input or vim.trim(input) == "" then
      callback(nil)
      return
    end

    local creds, err = exchange_auth_code(input, oauth.state, oauth.verifier)
    if not creds then
      vim.notify("sia: " .. err, vim.log.levels.ERROR)
      callback(nil)
      return
    end

    save_browser_token(creds)
    callback(creds)
  end)
end

M.spec = {
  implementations = {
    default = messages,
  },
  seed = {},
  authorize = authorize,
  discover = discover,
}

M._test = {
  build_billing_header = build_billing_header,
  compute_cch = compute_cch,
  compute_version_suffix = compute_version_suffix,
  extract_first_user_text = extract_first_user_text,
  parse_auth_code = parse_auth_code,
  exchange_auth_code = exchange_auth_code,
  prefix_tool_name = prefix_tool_name,
  rewrite_text = rewrite_text,
  unprefix_tool_name = unprefix_tool_name,
}

return M
