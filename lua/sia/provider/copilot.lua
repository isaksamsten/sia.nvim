local openai = require("sia.provider.openai")

local GITHUB_OAUTH_CLIENT_ID = "Iv1.b507a08c87ecfe98"
local DEVICE_CODE_URL = "https://github.com/login/device/code"
local ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token"
local COPILOT_TOKEN_URL = "https://api.github.com/copilot_internal/v2/token"
local COPILOT_USER_URL = "https://api.github.com/copilot_internal/user"
local OAUTH_POLLING_SAFETY_MARGIN_MS = 3000

local _api_token = nil
local _oauth_token = nil
local invalidate_api_token

---@return string
local function get_cache_dir()
  local cache_dir = vim.fn.stdpath("cache") .. "/sia"
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end
  return cache_dir
end

---@return string
local function get_oauth_cache_path()
  return get_cache_dir() .. "/copilot_oauth.json"
end

---@return string
local function get_token_cache_path()
  return get_cache_dir() .. "/copilot_token.json"
end

---@return table?
local function load_json_file(path)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), ""))
  end)
  if ok then
    return data
  end
  return nil
end

---@param path string
---@param data table
local function save_json_file(path, data)
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

---@param cmd string[]
---@return table?
local function curl_json_sync(cmd)
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local ok, json = pcall(vim.json.decode, result)
  if ok then
    return json
  end
  return nil
end

---@param url string
local function open_url(url)
  local open_cmd = nil
  if vim.fn.has("mac") > 0 then
    open_cmd = "open"
  elseif vim.fn.has("unix") > 0 then
    open_cmd = "xdg-open"
  elseif vim.fn.has("win32") > 0 then
    open_cmd = "start"
  end

  if open_cmd and vim.fn.executable(open_cmd) == 1 then
    vim.fn.jobstart({ open_cmd, url }, { detach = true })
    vim.notify("sia: opening browser for authorization...", vim.log.levels.INFO)
  else
    vim.notify("sia: open this URL to authorize:\n" .. url, vim.log.levels.INFO)
  end
end

---@return string?
local function load_cached_oauth_token()
  local cached = load_json_file(get_oauth_cache_path())
  if cached and cached.access_token then
    return cached.access_token
  end
  return nil
end

---@param token string
local function save_cached_oauth_token(token)
  save_json_file(get_oauth_cache_path(), {
    access_token = token,
    created_at = os.time(),
  })
end

---Get OAuth token from cache
---@param oauth string?
---@return string?
local function get_oauth_token(oauth)
  if oauth then
    return oauth
  end

  local cached = load_cached_oauth_token()
  if cached then
    return cached
  end

  return nil
end

---@param callback fun(data: table?)
local function authorize(callback)
  local device_data = curl_json_sync({
    "curl",
    "--silent",
    "--request",
    "POST",
    "--header",
    "Accept: application/json",
    "--header",
    "Content-Type: application/json",
    "--header",
    "User-Agent: Sia.nvim",
    "--data",
    vim.json.encode({
      client_id = GITHUB_OAUTH_CLIENT_ID,
      scope = "",
    }),
    DEVICE_CODE_URL,
  })

  if
    not device_data
    or not device_data.device_code
    or not device_data.verification_uri
  then
    vim.notify(
      "sia: failed to initiate OAuth device authorization.",
      vim.log.levels.ERROR
    )
    callback(nil)
    return
  end

  open_url(device_data.verification_uri)
  vim.notify(
    "sia: enter code in browser: " .. (device_data.user_code or ""),
    vim.log.levels.INFO
  )

  local interval_seconds = tonumber(device_data.interval) or 5
  local expires_in = tonumber(device_data.expires_in) or 900
  local deadline = os.time() + expires_in
  local completed = false

  local function finish(data)
    if completed then
      return
    end
    completed = true
    callback(data)
  end

  local function poll(interval_ms)
    vim.defer_fn(function()
      if completed then
        return
      end

      if os.time() > deadline then
        vim.notify("sia: authorization timed out.", vim.log.levels.ERROR)
        finish(nil)
        return
      end

      local token_data = curl_json_sync({
        "curl",
        "--silent",
        "--request",
        "POST",
        "--header",
        "Accept: application/json",
        "--header",
        "Content-Type: application/json",
        "--header",
        "User-Agent: Sia.nvim",
        "--data",
        vim.json.encode({
          client_id = GITHUB_OAUTH_CLIENT_ID,
          device_code = device_data.device_code,
          grant_type = "urn:ietf:params:oauth:grant-type:device_code",
        }),
        ACCESS_TOKEN_URL,
      })

      if not token_data then
        vim.notify("sia: oauth polling failed.", vim.log.levels.ERROR)
        finish(nil)
        return
      end

      if token_data.access_token then
        save_cached_oauth_token(token_data.access_token)
        invalidate_api_token()
        _oauth_token = token_data.access_token
        finish({ oauth_token = token_data.access_token })
        return
      end

      if token_data.error == "authorization_pending" then
        poll((interval_seconds * 1000) + OAUTH_POLLING_SAFETY_MARGIN_MS)
        return
      end

      if token_data.error == "slow_down" then
        local next_interval = tonumber(token_data.interval) or (interval_seconds + 5)
        interval_seconds = next_interval
        poll((next_interval * 1000) + OAUTH_POLLING_SAFETY_MARGIN_MS)
        return
      end

      if token_data.error then
        vim.notify(
          "sia: authorization failed: " .. token_data.error,
          vim.log.levels.ERROR
        )
      else
        vim.notify("sia: authorization failed.", vim.log.levels.ERROR)
      end
      finish(nil)
    end, interval_ms)
  end

  poll((interval_seconds * 1000) + OAUTH_POLLING_SAFETY_MARGIN_MS)
end

---@return table?
local function load_cached_api_token()
  local cached = load_json_file(get_token_cache_path())
  if cached and cached.token and cached.expires_at then
    cached.expires_at = tonumber(cached.expires_at)
    return cached
  end
  return nil
end

---@param token_data table
local function save_cached_api_token(token_data)
  save_json_file(get_token_cache_path(), token_data)
end

--- Invalidate the cached Copilot API token (both in-memory and on disk).
--- Called when the server rejects the token (e.g., 401).
invalidate_api_token = function()
  _api_token = nil
  local token_cache = get_token_cache_path()
  if vim.fn.filereadable(token_cache) == 1 then
    vim.fn.delete(token_cache)
  end
end

---Get a valid GitHub Copilot API key.
---Uses shared module-level state so all providers see the same token.
---@return string?
local function get_copilot_api_key()
  if
    _api_token
    and _api_token.expires_at
    and _api_token.expires_at - 60 > os.time()
  then
    return _api_token.token
  end

  _api_token = load_cached_api_token()
  if
    _api_token
    and _api_token.expires_at
    and _api_token.expires_at - 60 > os.time()
  then
    return _api_token.token
  end

  _oauth_token = get_oauth_token(_oauth_token)
  if not _oauth_token then
    vim.notify("sia: run :SiaAuth copilot to authorize", vim.log.levels.WARN)
    return nil
  end

  local json = curl_json_sync({
    "curl",
    "--silent",
    "--header",
    "Authorization: Bearer " .. _oauth_token,
    "--header",
    "Content-Type: application/json",
    "--header",
    "Accept: application/json",
    COPILOT_TOKEN_URL,
  })

  if json and json.token and json.expires_at then
    _api_token = {
      token = json.token,
      expires_at = tonumber(json.expires_at),
    }
    if _api_token.expires_at then
      save_cached_api_token(_api_token)
    end
    return _api_token.token
  end

  return nil
end

--- @param model sia.Model
local copilot_extra_header = function(model, _, messages)
  local args = {}
  table.insert(args, "--header")
  table.insert(args, "Copilot-Integration-Id: vscode-chat")
  table.insert(args, "--header")
  table.insert(
    args,
    string.format(
      "editor-version: Neovim/%s.%s.%s",
      vim.version().major,
      vim.version().minor,
      vim.version().patch
    )
  )
  table.insert(args, "--header")
  local initiator = "user"
  local last = messages[#messages]
  if last and (last.role == "tool" or (last.meta and last.meta.compaction)) then
    initiator = "agent"
  end
  table.insert(args, "X-Initiator: " .. initiator)
  table.insert(args, "--header")
  table.insert(args, "openai-intent: conversation-agent")
  table.insert(args, "--header")
  table.insert(args, "x-github-api-version: 2025-10-01")
  table.insert(args, "--header")
  table.insert(args, "x-interaction-type: conversation-agent")

  if
    model.support.reasoning
    and (model.api_name:match("claude") and not model.support.adaptive_thinking)
  then
    table.insert(args, "--header")
    table.insert(args, "anthropic-beta: interleaved-thinking-2025-05-14")
  end
  return args
end

--- @param callback fun(stats: sia.conversation.Stats?)
--- @param _conversation sia.Conversation
local function get_stats(callback, _conversation)
  local oauth = get_oauth_token(_oauth_token)
  if not oauth then
    callback()
    return
  end

  local cmd = {
    "curl",
    "--silent",
    "--header",
    "Authorization: Bearer " .. oauth,
    "--header",
    "Accept: */*",
    "--header",
    "User-Agent: Sia.nvim",
    COPILOT_USER_URL,
  }

  vim.system(
    cmd,
    { text = true },
    vim.schedule_wrap(function(response)
      local status, json = pcall(vim.json.decode, response.stdout)

      if not status then
        callback({})
        return
      end

      local premium = json.quota_snapshots and json.quota_snapshots.premium_interactions
      if not premium then
        callback({})
        return
      end

      local percent_remaining = premium.percent_remaining or 0
      local used_percent = 1 - (percent_remaining / 100)

      local label
      if json.quota_reset_date_utc then
        local year, month, day = json.quota_reset_date_utc:match("(%d+)-(%d+)-(%d+)")
        if year and month and day then
          local reset_time = os.time({
            year = tonumber(year) or 0,
            month = tonumber(month) or 0,
            day = tonumber(day) or 0,
          })
          local now = os.time()
          label = math.ceil((reset_time - now) / 86400) .. "d"
        end
      end

      callback({
        quota = { percent = used_percent, label = label },
      })
    end)
  )
end

--- Handle HTTP errors from the Copilot API.
--- On 401, invalidate the cached token and signal a retry.
--- @param http_status integer
--- @return boolean should_retry
local function copilot_on_http_error(http_status)
  if http_status == 401 then
    invalidate_api_token()
    return true
  end
  return false
end

local completion =
  openai.completion_compatible("https://api.githubcopilot.com/", "chat/completions", {
    api_key = get_copilot_api_key,
    get_headers = copilot_extra_header,
    prepare_parameters = function(data, model)
      if model.api_name:match("claude") and not data.max_tokens then
        data.max_tokens = 4096
      end
    end,
  })
completion.get_stats = get_stats
completion.on_http_error = copilot_on_http_error

local responses =
  openai.responses_compatible("https://api.githubcopilot.com/", "responses", {
    api_key = get_copilot_api_key,
    get_headers = copilot_extra_header,
    prepare_parameters = function(data, model)
      if model.api_name:match("claude") and not data.max_tokens then
        data.max_tokens = 4096
      end
    end,
  })
responses.get_stats = get_stats
responses.on_http_error = copilot_on_http_error

return {
  completion = completion,
  responses = responses,
  authorize = authorize,
}
