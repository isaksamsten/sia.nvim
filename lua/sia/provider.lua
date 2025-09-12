local M = {}

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

  ---Closure that manages token state and retrieves a valid Copilot API token
  ---@return string? token A valid Copilot API token or nil if the request fails
  return function()
    if token and token.expires_at > os.time() then
      return token.token
    end

    oauth = get_oauth_token()
    if not oauth then
      vim.notify("Sia: Can't find Copilot auth token")
    end

    local cmd = table.concat({
      "curl",
      "--silent",
      "--header \"Authorization: Bearer " .. oauth .. "\"",
      "--header \"Content-Type: application/json\"",
      "--header \"Accept: application/json\"",
      "https://api.github.com/copilot_internal/v2/token",
    }, " ")
    local response = vim.fn.system(cmd)
    local status, json = pcall(vim.json.decode, response)
    if status then
      token = json
      return token.token
    end
  end
end

--- @type sia.config.Provider
M.copilot = { base_url = "https://api.githubcopilot.com/chat/completions", api_key = copilot_api_key() }

--- @type sia.config.Provider
M.openai = {
  base_url = "https://api.openai.com/v1/chat/completions",
  api_key = function()
    return os.getenv("OPENAI_API_KEY")
  end,
}

M.gemini = {
  base_url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
  api_key = function()
    return os.getenv("GEMINI_API_KEY")
  end,
}

M.anthropic = {
  base_url = "https://api.anthropic.com/v1/chat/completions",
  api_key = function()
    return os.getenv("ANTHROPIC_API_KEY")
  end,
}

M.ollama = {
  base_url = "http://localhost:11434/v1/chat/completions",
  api_key = function()
    return "ollama"
  end,
}

M.morph = {
  base_url = "https://api.morphllm.com/v1/chat/completions",
  api_key = function()
    return os.getenv("MORPH_API_KEY")
  end,
}

local OR_CACHING_PREFIXES = { "anthropic/", "google/" }
M.openrouter = {
  base_url = "https://openrouter.ai/api/v1/chat/completions",
  api_key = function()
    return os.getenv("OPENROUTER_API_KEY")
  end,
  --- @param model string
  --- @param prompt sia.Prompt[]
  format_messages = function(model, prompts)
    local should_cache = false
    for _, prefix in ipairs(OR_CACHING_PREFIXES) do
      if model:find(prefix, 1, true) == 1 then
        should_cache = true
        break
      end
    end

    if should_cache then
      local last_system_idx = nil
      local last_user_idx = nil
      for i = #prompts, 1, -1 do
        if prompts[i].role == "system" then
          last_system_idx = i
          break
        end
      end
      for i = #prompts, 1, -1 do
        if prompts[i].role == "user" then
          last_user_idx = i
          break
        end
      end
      for i, prompt in ipairs(prompts) do
        if i == last_system_idx then
          prompt.content = { { type = "text", text = prompt.content, cache_control = { type = "ephemeral" } } }
        elseif i == last_user_idx then
          prompt.content = { { type = "text", text = prompt.content, cache_control = { type = "ephemeral" } } }
        end
      end
    end
  end,
}

return M
