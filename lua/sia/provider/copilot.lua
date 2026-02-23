local openai = require("sia.provider.openai")
local common = require("sia.provider.common")

local GITHUB_OAUTH_CLIENT_ID = "Iv1.b507a08c87ecfe98"
local DEVICE_CODE_URL = "https://github.com/login/device/code"
local ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token"
local COPILOT_TOKEN_URL = "https://api.github.com/copilot_internal/v2/token"
local COPILOT_USER_URL = "https://api.github.com/copilot_internal/user"
local OAUTH_POLLING_SAFETY_MARGIN_MS = 3000

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
    vim.notify("Sia Copilot: Opening browser for authorization...", vim.log.levels.INFO)
  else
    vim.notify("Sia Copilot: Open this URL to authorize:\n" .. url, vim.log.levels.INFO)
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
      "Sia Copilot: Failed to initiate OAuth device authorization.",
      vim.log.levels.ERROR
    )
    callback(nil)
    return
  end

  open_url(device_data.verification_uri)
  vim.notify(
    "Sia Copilot: Enter code in browser: " .. (device_data.user_code or ""),
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
        vim.notify("Sia Copilot: Authorization timed out.", vim.log.levels.ERROR)
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
        vim.notify("Sia Copilot: OAuth polling failed.", vim.log.levels.ERROR)
        finish(nil)
        return
      end

      if token_data.access_token then
        save_cached_oauth_token(token_data.access_token)
        -- Clear cached API token so the new OAuth token is used for the next exchange
        local token_cache = get_token_cache_path()
        if vim.fn.filereadable(token_cache) == 1 then
          vim.fn.delete(token_cache)
        end
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
          "Sia Copilot: Authorization failed: " .. token_data.error,
          vim.log.levels.ERROR
        )
      else
        vim.notify("Sia Copilot: Authorization failed.", vim.log.levels.ERROR)
      end
      finish(nil)
    end, interval_ms)
  end

  poll((interval_seconds * 1000) + OAUTH_POLLING_SAFETY_MARGIN_MS)
end

---Get a valid GitHub Copilot API key by:
---1. Looking up the OAuth token from cache
---2. Exchanging the OAuth token for a temporary API token via /copilot_internal/v2/token
---@return function(): string? Function that returns a valid Copilot API token or nil if unsuccessful
local function copilot_api_key()
  local token = nil
  local oauth = nil

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

  ---@return string?
  return function()
    -- Check in-memory cache first
    if token and token.expires_at and token.expires_at > os.time() then
      return token.token
    end

    -- Check disk cache
    token = load_cached_api_token()
    if token and token.expires_at and token.expires_at > os.time() then
      return token.token
    end

    -- Need to fetch a new token
    oauth = get_oauth_token(oauth)
    if not oauth then
      vim.notify(
        "Sia Copilot: Not authenticated. Run :SiaAuth copilot to authorize.",
        vim.log.levels.WARN
      )
      return nil
    end

    local json = curl_json_sync({
      "curl",
      "--silent",
      "--header",
      "Authorization: Bearer " .. oauth,
      "--header",
      "Content-Type: application/json",
      "--header",
      "Accept: application/json",
      COPILOT_TOKEN_URL,
    })

    if json and json.token and json.expires_at then
      token = {
        token = json.token,
        expires_at = tonumber(json.expires_at),
      }
      if token.expires_at then
        save_cached_api_token(token)
      end
      return token.token
    end

    return nil
  end
end

local copilot_extra_header = function(_, messages)
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
  if last and last.role == "tool" then
    initiator = "agent"
  end
  table.insert(args, "X-Initiator: " .. initiator)
  return args
end

--- @param callback fun(stats: sia.conversation.Stats?)
--- @param conversation sia.Conversation
local function get_stats(callback, conversation)
  local oauth = get_oauth_token()
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

      local token_display = ""
      if conversation then
        local usage = conversation:get_cumulative_usage()
        if usage and usage.total > 0 then
          token_display = common.format_token_count(usage.total)
        end
      end

      if status then
        local premium = json.quota_snapshots
          and json.quota_snapshots.premium_interactions
        if not premium then
          callback({ right = token_display })
          return
        end

        local percent_remaining = premium.percent_remaining or 0
        local used_percent = 1 - (percent_remaining / 100)
        local percent_display = string.format("%d%%%%", math.floor(used_percent * 100))

        local days_remaining
        if json.quota_reset_date_utc then
          local year, month, day = json.quota_reset_date_utc:match("(%d+)-(%d+)-(%d+)")
          if year and month and day then
            local reset_time = os.time({
              year = tonumber(year) or 0,
              month = tonumber(month) or 0,
              day = tonumber(day) or 0,
            })
            local now = os.time()
            days_remaining = math.ceil((reset_time - now) / 86400) .. "d"
          end
        end

        callback({
          bar = { percent = used_percent, icon = " ", text = percent_display },
          left = days_remaining,
          right = token_display,
        })
      else
        callback({ right = token_display })
      end
    end)
  )
end

local completion =
  openai.completion_compatible("https://api.githubcopilot.com/", "chat/completions", {
    api_key = copilot_api_key(),
    get_headers = copilot_extra_header,
  })
completion.get_stats = get_stats

local responses =
  openai.responses_compatible("https://api.githubcopilot.com/", "responses", {
    api_key = copilot_api_key(),
    get_headers = copilot_extra_header,
  })
responses.get_stats = get_stats

return {
  completion = completion,
  responses = responses,
  authorize = authorize,
}
