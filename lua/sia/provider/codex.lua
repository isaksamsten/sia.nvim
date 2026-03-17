--- Codex provider for ChatGPT Pro/Plus subscriptions
--- Uses OAuth PKCE browser flow for authentication
--- Based on the OpenAI Responses API format
--- Implementation based on: https://github.com/anomalyco/opencode/packages/opencode/src/plugin/codex.ts
local openai = require("sia.provider.openai")
local common = require("sia.provider.common")

local CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
local ISSUER = "https://auth.openai.com"
local CODEX_API_BASE = "https://chatgpt.com/backend-api/codex/"
local CODEX_CHAT_ENDPOINT = "responses"
local OAUTH_PORT = 1455
local OAUTH_TIMEOUT_MS = 5 * 60 * 1000 -- 5 minutes

--- @class sia.codex.TokenData
--- @field access_token string
--- @field refresh_token string
--- @field id_token string?
--- @field expires_at integer timestamp in seconds
--- @field account_id string?

--- Get the cache file path for storing codex tokens
--- @return string
local function get_cache_path()
  local cache_dir = vim.fn.stdpath("cache") .. "/sia"
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, "p")
  end
  return cache_dir .. "/codex_token.json"
end

--- Load cached token from disk
--- @return sia.codex.TokenData?
local function load_cached_token()
  local cache_path = get_cache_path()
  if vim.fn.filereadable(cache_path) == 0 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(cache_path), ""))
  end)
  if ok and data and data.access_token and data.refresh_token and data.expires_at then
    return data
  end
  return nil
end

--- Save token data to disk cache
--- @param token_data sia.codex.TokenData
local function save_cached_token(token_data)
  local cache_path = get_cache_path()
  vim.fn.writefile({ vim.json.encode(token_data) }, cache_path)
end

--- Base64url encode raw bytes
--- @param bytes string raw bytes
--- @return string
local function base64url_encode(bytes)
  local b64 = vim.base64.encode(bytes)
  return b64:gsub("+", "-"):gsub("/", "_"):gsub("=+$", "")
end

--- Decode a base64url-encoded string
--- @param s string
--- @return string
local function base64url_decode(s)
  s = s:gsub("-", "+"):gsub("_", "/")
  local remainder = #s % 4
  if remainder == 2 then
    s = s .. "=="
  elseif remainder == 3 then
    s = s .. "="
  end
  return vim.base64.decode(s)
end

--- Generate a random string suitable for PKCE verifier
--- @param length integer
--- @return string
local function generate_random_string(length)
  local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  local bytes = {}
  -- Read from /dev/urandom for cryptographic randomness
  local f = io.open("/dev/urandom", "rb")
  if f then
    local raw = f:read(length)
    f:close()
    for i = 1, #raw do
      bytes[i] = raw:byte(i)
    end
  else
    -- Fallback: math.random (less secure but functional)
    math.randomseed(os.time() + vim.uv.hrtime())
    for i = 1, length do
      bytes[i] = math.random(0, 255)
    end
  end
  local result = {}
  for i = 1, length do
    result[i] = chars:sub((bytes[i] % #chars) + 1, (bytes[i] % #chars) + 1)
  end
  return table.concat(result)
end

--- Generate PKCE code verifier and challenge
--- @return { verifier: string, challenge: string }
local function generate_pkce()
  local verifier = generate_random_string(43)
  -- SHA-256 hash via openssl (available on macOS/Linux)
  local cmd =
    string.format("printf '%%s' '%s' | openssl dgst -sha256 -binary", verifier)
  local hash = vim.fn.system(cmd)
  local challenge = base64url_encode(hash)
  return { verifier = verifier, challenge = challenge }
end

--- Generate a random state parameter
--- @return string
local function generate_state()
  local f = io.open("/dev/urandom", "rb")
  local raw
  if f then
    raw = f:read(32)
    f:close()
  else
    math.randomseed(os.time() + vim.uv.hrtime())
    local bytes = {}
    for i = 1, 32 do
      bytes[i] = string.char(math.random(0, 255))
    end
    raw = table.concat(bytes)
  end
  return base64url_encode(raw)
end

--- Parse JWT claims from a token
--- @param token string
--- @return table?
local function parse_jwt_claims(token)
  local parts = vim.split(token, ".", { plain = true })
  if #parts ~= 3 then
    return nil
  end
  local ok, claims = pcall(function()
    return vim.json.decode(base64url_decode(parts[2]))
  end)
  if ok then
    return claims
  end
  return nil
end

--- Extract account ID from JWT claims
--- @param claims table
--- @return string?
local function extract_account_id_from_claims(claims)
  if claims.chatgpt_account_id then
    return claims.chatgpt_account_id
  end
  local auth = claims["https://api.openai.com/auth"]
  if auth and auth.chatgpt_account_id then
    return auth.chatgpt_account_id
  end
  if claims.organizations and #claims.organizations > 0 then
    return claims.organizations[1].id
  end
  return nil
end

--- Extract account ID from token response
--- @param id_token string?
--- @param access_token string?
--- @return string?
local function extract_account_id(id_token, access_token)
  if id_token then
    local claims = parse_jwt_claims(id_token)
    if claims then
      local account_id = extract_account_id_from_claims(claims)
      if account_id then
        return account_id
      end
    end
  end
  if access_token then
    local claims = parse_jwt_claims(access_token)
    if claims then
      return extract_account_id_from_claims(claims)
    end
  end
  return nil
end

--- Synchronously run curl and return decoded JSON
--- @param cmd string[]
--- @return table?
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

--- Refresh access token using refresh_token
--- @param refresh_token string
--- @return sia.codex.TokenData?
local function refresh_access_token(refresh_token)
  local body = table.concat({
    "grant_type=refresh_token",
    "refresh_token=" .. vim.uri_encode(refresh_token),
    "client_id=" .. vim.uri_encode(CLIENT_ID),
  }, "&")

  local json = curl_json_sync({
    "curl",
    "--silent",
    "--request",
    "POST",
    "--header",
    "Content-Type: application/x-www-form-urlencoded",
    "--data",
    body,
    ISSUER .. "/oauth/token",
  })

  if not json or not json.access_token then
    return nil
  end

  local expires_in = json.expires_in or 3600
  local account_id = extract_account_id(json.id_token, json.access_token)

  return {
    access_token = json.access_token,
    refresh_token = json.refresh_token or refresh_token,
    id_token = json.id_token,
    expires_at = os.time() + expires_in,
    account_id = account_id,
  }
end

--- HTML response for successful OAuth callback
local HTML_SUCCESS = [[<!doctype html>
<html><head><title>Sia - Codex Authorization Successful</title>
<style>body{font-family:system-ui,-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#131010;color:#f1ecec}.container{text-align:center;padding:2rem}h1{margin-bottom:1rem}p{color:#b7b1b1}</style>
</head><body><div class="container"><h1>Authorization Successful</h1>
<p>You can close this window and return to Neovim.</p></div>
<script>setTimeout(()=>window.close(),2000)</script></body></html>]]

--- HTML response for failed OAuth callback
--- @param error_msg string
--- @return string
local function html_error(error_msg)
  return string.format(
    [[<!doctype html>
<html><head><title>Sia - Codex Authorization Failed</title>
<style>body{font-family:system-ui,-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#131010;color:#f1ecec}.container{text-align:center;padding:2rem}h1{color:#fc533a;margin-bottom:1rem}p{color:#b7b1b1}.error{color:#ff917b;font-family:monospace;margin-top:1rem;padding:1rem;background:#3c140d;border-radius:.5rem}</style>
</head><body><div class="container"><h1>Authorization Failed</h1>
<p>An error occurred during authorization.</p>
<div class="error">%s</div></div></body></html>]],
    error_msg
  )
end

--- Build the OAuth authorize URL
--- @param redirect_uri string
--- @param pkce { verifier: string, challenge: string }
--- @param state string
--- @return string
local function build_authorize_url(redirect_uri, pkce, state)
  local params = {
    "response_type=code",
    "client_id=" .. vim.uri_encode(CLIENT_ID),
    "redirect_uri=" .. vim.uri_encode(redirect_uri),
    "scope=" .. vim.uri_encode("openid profile email offline_access"),
    "code_challenge=" .. vim.uri_encode(pkce.challenge),
    "code_challenge_method=S256",
    "id_token_add_organizations=true",
    "codex_cli_simplified_flow=true",
    "state=" .. vim.uri_encode(state),
    "originator=sia",
  }
  return ISSUER .. "/oauth/authorize?" .. table.concat(params, "&")
end

--- Parse query string from a URL path
--- @param url string e.g. "/auth/callback?code=xxx&state=yyy"
--- @return string path, table<string,string> params
local function parse_url(url)
  local path, query = url:match("^([^?]*)%??(.*)")
  path = path or url
  local params = {}
  if query then
    for key, value in query:gmatch("([^&=]+)=([^&]*)") do
      params[key] = vim.uri_decode(value)
    end
  end
  return path, params
end

--- Format an HTTP response
--- @param status string e.g. "200 OK"
--- @param content_type string
--- @param body string
--- @return string
local function http_response(status, content_type, body)
  return table.concat({
    "HTTP/1.1 " .. status,
    "Content-Type: " .. content_type,
    "Content-Length: " .. #body,
    "Connection: close",
    "",
    body,
  }, "\r\n")
end

--- Exchange authorization code for tokens
--- @param code string
--- @param redirect_uri string
--- @param pkce { verifier: string, challenge: string }
--- @param callback fun(token_data: sia.codex.TokenData?)
local function exchange_code_for_tokens(code, redirect_uri, pkce, callback)
  local body = table.concat({
    "grant_type=authorization_code",
    "code=" .. vim.uri_encode(code),
    "redirect_uri=" .. vim.uri_encode(redirect_uri),
    "client_id=" .. vim.uri_encode(CLIENT_ID),
    "code_verifier=" .. vim.uri_encode(pkce.verifier),
  }, "&")

  vim.system(
    {
      "curl",
      "--silent",
      "--request",
      "POST",
      "--header",
      "Content-Type: application/x-www-form-urlencoded",
      "--data",
      body,
      ISSUER .. "/oauth/token",
    },
    { text = true },
    vim.schedule_wrap(function(result)
      if not result or result.code ~= 0 then
        callback(nil)
        return
      end
      local ok, tokens = pcall(vim.json.decode, result.stdout)
      if not ok or not tokens or not tokens.access_token then
        callback(nil)
        return
      end
      local expires_in = tokens.expires_in or 3600
      local account_id = extract_account_id(tokens.id_token, tokens.access_token)
      callback({
        access_token = tokens.access_token,
        refresh_token = tokens.refresh_token,
        id_token = tokens.id_token,
        expires_at = os.time() + expires_in,
        account_id = account_id,
      })
    end)
  )
end

--- Start a local OAuth callback server using libuv TCP
--- @param callback fun(token_data: sia.codex.TokenData?)
local function browser_authorize(callback)
  local pkce = generate_pkce()
  local state = generate_state()
  local redirect_uri = string.format("http://localhost:%d/auth/callback", OAUTH_PORT)
  local server = vim.uv.new_tcp()
  local completed = false
  local timeout_timer = vim.uv.new_timer()

  local function cleanup()
    if completed then
      return
    end
    completed = true
    pcall(function()
      timeout_timer:stop()
      timeout_timer:close()
    end)
    pcall(function()
      server:close()
    end)
  end

  -- Timeout after 5 minutes
  timeout_timer:start(
    OAUTH_TIMEOUT_MS,
    0,
    vim.schedule_wrap(function()
      if not completed then
        cleanup()
        vim.notify("sia: authorization timed out", vim.log.levels.ERROR)
        callback(nil)
      end
    end)
  )

  server:bind("127.0.0.1", OAUTH_PORT)
  server:listen(128, function(err)
    if err then
      vim.schedule(function()
        cleanup()
        vim.notify("sia: failed to start oauth server: " .. err, vim.log.levels.ERROR)
        callback(nil)
      end)
      return
    end

    local client = vim.uv.new_tcp()
    server:accept(client)

    local request_data = ""
    client:read_start(function(read_err, data)
      if read_err or not data then
        pcall(function()
          client:close()
        end)
        return
      end

      request_data = request_data .. data

      -- Wait for complete HTTP request (ends with \r\n\r\n)
      if not request_data:find("\r\n\r\n") then
        return
      end

      -- Parse the HTTP request line
      local request_line = request_data:match("^(.-)\r\n")
      local url = request_line and request_line:match("^%w+%s+(%S+)")
      if not url then
        local resp = http_response("400 Bad Request", "text/plain", "Bad request")
        client:write(resp, function()
          pcall(function()
            client:close()
          end)
        end)
        return
      end

      local path, params = parse_url(url)

      vim.schedule(function()
        if path == "/auth/callback" then
          -- Check for error
          if params.error then
            local error_msg = params.error_description or params.error
            local resp = http_response("200 OK", "text/html", html_error(error_msg))
            client:write(resp, function()
              pcall(function()
                client:close()
              end)
            end)
            cleanup()
            vim.notify("sia: authorization failed: " .. error_msg, vim.log.levels.ERROR)
            callback(nil)
            return
          end

          -- Check for missing code
          if not params.code then
            local resp = http_response(
              "400 Bad Request",
              "text/html",
              html_error("Missing authorization code")
            )
            client:write(resp, function()
              pcall(function()
                client:close()
              end)
            end)
            cleanup()
            vim.notify("sia: missing authorization code", vim.log.levels.ERROR)
            callback(nil)
            return
          end

          -- Validate state
          if params.state ~= state then
            local resp = http_response(
              "400 Bad Request",
              "text/html",
              html_error("Invalid state parameter")
            )
            client:write(resp, function()
              pcall(function()
                client:close()
              end)
            end)
            cleanup()
            vim.notify("sia: invalid state", vim.log.levels.ERROR)
            callback(nil)
            return
          end

          -- Send success response immediately
          local resp = http_response("200 OK", "text/html", HTML_SUCCESS)
          client:write(resp, function()
            pcall(function()
              client:close()
            end)
          end)
          cleanup()

          -- Exchange code for tokens
          exchange_code_for_tokens(params.code, redirect_uri, pkce, function(token_data)
            if token_data then
              save_cached_token(token_data)
              vim.notify("sia: authorization successful", vim.log.levels.INFO)
            else
              vim.notify("sia: token exchange failed", vim.log.levels.ERROR)
            end
            callback(token_data)
          end)
        else
          local resp = http_response("404 Not Found", "text/plain", "Not found")
          client:write(resp, function()
            pcall(function()
              client:close()
            end)
          end)
        end
      end)
    end)
  end)

  -- Build authorize URL and open browser
  local auth_url = build_authorize_url(redirect_uri, pkce, state)

  local open_cmd
  if vim.fn.has("mac") == 1 then
    open_cmd = "open"
  elseif vim.fn.has("unix") == 1 then
    open_cmd = "xdg-open"
  elseif vim.fn.has("win32") == 1 then
    open_cmd = "start"
  end

  if open_cmd and vim.fn.executable(open_cmd) == 1 then
    vim.fn.jobstart({ open_cmd, auth_url }, { detach = true })
  else
    vim.notify("sia: open this url to authorize:\n" .. auth_url, vim.log.levels.INFO)
  end
end

--- Token state management
--- @type sia.codex.TokenData?
local cached_token = nil

--- Get a valid access token, refreshing if needed
--- Returns nil if no token is available (user needs to authorize)
--- @return string? access_token
local function get_access_token()
  if cached_token and cached_token.expires_at > os.time() + 60 then
    return cached_token.access_token
  end

  cached_token = load_cached_token()
  if cached_token and cached_token.expires_at > os.time() + 60 then
    return cached_token.access_token
  end

  if cached_token and cached_token.refresh_token then
    local refreshed = refresh_access_token(cached_token.refresh_token)
    if refreshed then
      cached_token = refreshed
      save_cached_token(cached_token)
      return cached_token.access_token
    end
  end

  return nil
end

--- Get the account ID from cached token
--- @return string?
local function get_account_id()
  if cached_token then
    return cached_token.account_id
  end
  local loaded = load_cached_token()
  if loaded then
    return loaded.account_id
  end
  return nil
end

--- API key function for the provider (returns access token)
--- @return string?
local function codex_api_key()
  local token = get_access_token()
  if not token then
    vim.notify("sia: run :SiaAuth codex to authorize", vim.log.levels.WARN)
    return nil
  end
  return token
end

--- Build the Codex responses provider using OpenAI responses as base
local codex = openai.responses_compatible(CODEX_API_BASE, CODEX_CHAT_ENDPOINT, {
  api_key = codex_api_key,
  get_headers = function(model, api_key, messages)
    -- We handle all headers ourselves, return extras beyond Authorization
    local headers = {}
    local account_id = get_account_id()
    if account_id then
      table.insert(headers, "--header")
      table.insert(headers, string.format("ChatGPT-Account-Id: %s", account_id))
    end
    table.insert(headers, "--header")
    table.insert(headers, "originator: sia")
    table.insert(headers, "--header")
    table.insert(
      headers,
      string.format(
        "User-Agent: sia.nvim (%s %s; %s)",
        vim.uv.os_uname().sysname,
        vim.uv.os_uname().release,
        vim.uv.os_uname().machine
      )
    )
    return headers
  end,
})

codex.get_stats = common.create_cost_stats()

return {
  responses = codex,
  authorize = browser_authorize,
}
