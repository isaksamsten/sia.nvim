local openai = require("sia.provider.openai")

---Get a valid GitHub Copilot API key by:
---1. Looking up the OAuth token in the GitHub Copilot config
---2. Using the OAuth token to request a temporary access token from GitHub's API
---@return function(): string? Function that returns a valid Copilot API token or nil if unsuccessful
local function copilot_api_key()
  local token = nil
  local oauth = nil

  ---Find the appropriate configuration directory based on the OS
  ---@return string? config_path The full path to the config directory or nil if not found
  local function find_config()
    local config = vim.fn.expand("$XDG_CONFIG_HOME")
    if config and vim.fn.isdirectory(config) > 0 then
      return config
    elseif vim.fn.has("win32") > 0 then
      config = vim.fn.expand("~/AppData/Local")
      if vim.fn.isdirectory(config) > 0 then
        return config
      end
    else
      config = vim.fn.expand("~/.config")
      if vim.fn.isdirectory(config) > 0 then
        return config
      end
    end
  end

  ---Extract the OAuth token from the GitHub Copilot apps.json configuration file
  ---@return string? oauth_token The OAuth token if found, nil otherwise
  local function get_oauth_token()
    if oauth then
      return oauth
    end
    local config_home = find_config()
    if not config_home then
      return nil
    end
    local apps = config_home .. "/github-copilot/apps.json"
    if vim.fn.filereadable(apps) == 1 then
      local data = vim.json.decode(table.concat(vim.fn.readfile(apps), " "))
      for key, value in pairs(data) do
        if string.find(key, "github.com") then
          return value.oauth_token
        end
      end
    end
    return nil
  end

  ---Get the cache file path for storing the token
  ---@return string cache_path The full path to the cache file
  local function get_cache_path()
    local cache_dir = vim.fn.stdpath("cache") .. "/sia"
    if vim.fn.isdirectory(cache_dir) == 0 then
      vim.fn.mkdir(cache_dir, "p")
    end
    return cache_dir .. "/copilot_token.json"
  end

  ---Load token from disk cache if it exists
  ---@return table? token The cached token or nil if not found
  local function load_cached_token()
    local cache_path = get_cache_path()
    if vim.fn.filereadable(cache_path) == 0 then
      return nil
    end
    local status, cached = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(cache_path), ""))
    end)
    if status and cached then
      return cached
    end
    return nil
  end

  ---Save token to disk cache
  ---@param token_data table The token data to cache
  local function save_cached_token(token_data)
    local cache_path = get_cache_path()
    vim.fn.writefile({ vim.json.encode(token_data) }, cache_path)
  end

  ---Closure that manages token state and retrieves a valid Copilot API token
  ---@return string? token A valid Copilot API token or nil if the request fails
  return function()
    -- Check in-memory cache first
    if token and token.expires_at > os.time() then
      return token.token
    end

    -- Check disk cache
    token = load_cached_token()
    if token and token.expires_at and token.expires_at > os.time() then
      return token.token
    end

    -- Need to fetch a new token
    oauth = get_oauth_token()
    if not oauth then
      vim.notify("Sia: Can't find Copilot auth token")
      return nil
    end

    local cmd = table.concat({
      "curl",
      "--silent",
      '--header "Authorization: Bearer ' .. oauth .. '"',
      '--header "Content-Type: application/json"',
      '--header "Accept: application/json"',
      "https://api.github.com/copilot_internal/v2/token",
    }, " ")
    local response = vim.fn.system(cmd)
    local status, json = pcall(vim.json.decode, response)
    if status and json and json.token and json.expires_at then
      token = json
      save_cached_token(token)
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

return {
  completion = openai.completion_compatible(
    "https://api.githubcopilot.com/chat/completions",
    {
      api_key = copilot_api_key(),
      get_headers = copilot_extra_header,
    }
  ),
  responses = openai.responses_compatible("https://api.githubcopilot.com/responses", {
    api_key = copilot_api_key(),
    get_headers = copilot_extra_header,
  }),
}
