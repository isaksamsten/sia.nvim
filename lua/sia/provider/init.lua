local M = {}

local PROVIDERS = {
  "openai",
  "copilot",
  "codex",
  "anthropic",
  "openrouter",
  "gemini",
  "zai",
  "deepseek",
}

--- @class sia.Provider
--- @field base_url string
--- @field chat_endpoint string
--- @field api_key fun():string?
--- @field process_usage (fun(obj:table):sia.Usage?)?
--- @field process_response fun(json:table):string?
--- @field prepare_messages fun(data: table, model:string, prompt:sia.Message[])
--- @field prepare_tools fun(data: table, tools:sia.tool.Definition[])
--- @field prepare_parameters fun(data: table, model: sia.Model)?
--- @field get_headers (fun(model: sia.Model, api_key:string?, messages:sia.Message[]? ):string[])?
--- @field translate_http_error (fun(code: integer):string?)?
--- @field on_http_error (fun(code: integer):boolean)?
--- @field new_stream fun(strategy: sia.Strategy):sia.ProviderStream
--- @field get_stats fun(callback:fun(stats: sia.conversation.Stats), conversation: sia.Conversation)?

--- @class sia.provider.ProviderSpec
--- @field implementations table<string, sia.Provider>
--- @field seed table<string, sia.provider.ModelSpec>?
--- @field discover (fun(callback: fun(entries: table<string, sia.provider.ModelSpec>?, err: string?)))?
--- @field authorize (fun(callback: fun(data: any?)))?

--- @class sia.provider.ModelSpec
--- @field implementation string?
--- @field api_name string?
--- @field context_window integer?
--- @field support sia.config.Support?
--- @field pricing { input: number, output: number }?
--- @field cache_multiplier { read: number, write: number }?
--- @field options table<string, any>?
--- @field response_format table?

--- @class sia.provider.Model
--- @field name string
--- @field provider_name string
--- @field short_name string
--- @field api_name string
--- @field context_window integer?
--- @field support sia.config.Support?
--- @field pricing { input: number, output: number }?
--- @field cache_multiplier { read: number, write: number }?
--- @field options table<string, any>?
--- @field response_format table?
--- @field provider sia.Provider

--- @type table<string, sia.provider.ProviderSpec>
local providers = {}

--- @type table<string, table<string, sia.provider.ModelSpec>>
local cache = {}

--- @type table<string, sia.config.ModelOptions>
local setup_overrides = {}

local CACHE_VERSION = 1
local CACHE_FILENAME = "models-v1.json"

--- @return string
local function get_cache_path()
  local state_dir = vim.fn.stdpath("state") .. "/sia"
  return state_dir .. "/" .. CACHE_FILENAME
end

local function load_cache()
  local path = get_cache_path()
  if vim.fn.filereadable(path) == 0 then
    return
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), ""))
  end)
  if not ok or type(data) ~= "table" then
    return
  end
  if data.version ~= CACHE_VERSION then
    vim.notify("sia: ignoring model cache with unknown version", vim.log.levels.WARN)
    return
  end
  if data.providers and type(data.providers) == "table" then
    for provider_name, provider_data in pairs(data.providers) do
      if type(provider_data) == "table" and type(provider_data.entries) == "table" then
        cache[provider_name] = provider_data.entries
      end
    end
  end
end

local function save_cache()
  local path = get_cache_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local data = { version = CACHE_VERSION, providers = {} }
  for provider_name, entries in pairs(cache) do
    data.providers[provider_name] = {
      updated_at = os.time(),
      entries = entries,
    }
  end
  pcall(vim.fn.writefile, { vim.json.encode(data) }, path)
end

--- @param full_name string
--- @return string?
--- @return string?
local function parse_name(full_name)
  local slash = full_name:find("/", 1, true)
  if not slash or slash == 1 or slash == #full_name then
    return nil, nil
  end
  return full_name:sub(1, slash - 1), full_name:sub(slash + 1)
end

--- @param base sia.provider.ModelSpec?
--- @param overlay sia.provider.ModelSpec?
--- @return sia.provider.ModelSpec
local function merge_entries(base, overlay)
  if not base then
    return overlay or {}
  end
  if not overlay then
    return base
  end
  local result = vim.tbl_extend("force", {}, base)
  for k, v in pairs(overlay) do
    if k == "options" and type(result.options) == "table" and type(v) == "table" then
      result.options = vim.tbl_deep_extend("force", result.options, v)
    elseif
      k == "support"
      and type(result.support) == "table"
      and type(v) == "table"
    then
      result.support = vim.tbl_deep_extend("force", result.support, v)
    else
      result[k] = v
    end
  end
  return result
end

--- @param name string
--- @param spec sia.provider.ProviderSpec
function M.register(name, spec)
  providers[name] = spec
end

--- Disable a provider
--- @param name string
function M.disable(name)
  providers[name] = nil
end

--- @param name string
--- @return boolean
function M.is_enabled(name)
  return providers[name] ~= nil
end

--- @param name string
--- @param callback fun(data: any?)
function M.authorize(name, callback)
  local spec = providers[name]
  if spec and spec.authorize then
    spec.authorize(callback)
  end
end

--- @param full_name string
--- @return sia.provider.Model
function M.resolve_model(full_name)
  local provider_name, short_name = parse_name(full_name)
  if not provider_name or not short_name then
    error(string.format("Invalid model name format: '%s'", full_name))
  end

  local spec = providers[provider_name]
  if not spec then
    error(string.format("Unknown provider: '%s'", provider_name))
  end

  local entry = spec.seed and spec.seed[short_name] or nil
  local cached = cache[provider_name] and cache[provider_name][short_name] or nil
  entry = merge_entries(entry, cached)

  if entry then
    local setup_ov = setup_overrides[provider_name]
        and setup_overrides[provider_name][short_name]
      or nil
    if setup_ov then
      entry.options = vim.tbl_extend("force", entry.options or {}, setup_ov)
    end
  end

  if not entry then
    error(string.format("Unknown model: '%s'", full_name))
  end

  local impl_name = entry.implementation or "default"
  local transport = spec.implementations[impl_name]
  if not transport then
    error(
      string.format(
        "Unknown implementation '%s' for provider '%s'",
        impl_name,
        provider_name
      )
    )
  end

  --- @type sia.provider.Model
  return {
    name = full_name,
    provider_name = provider_name,
    short_name = short_name,
    provider = transport,
    api_name = entry.api_name or short_name,
    context_window = entry.context_window,
    support = entry.support,
    pricing = entry.pricing,
    cache_multiplier = entry.cache_multiplier,
    options = entry.options,
    response_format = entry.response_format,
  }
end

--- @param full_name string
--- @return boolean
function M.has_model(full_name)
  local ok, _ = pcall(M.resolve_model, full_name)
  return ok
end

function M.list_providers()
  return vim.tbl_keys(providers)
end

--- @param provider string?
--- @return string[]
function M.list(provider)
  local result = {}
  for provider_name, spec in pairs(providers) do
    if not provider or provider_name == provider then
      local model_names = {}

      if spec.seed then
        for short_name, _ in pairs(spec.seed) do
          model_names[short_name] = true
        end
      end

      if cache[provider_name] then
        for short_name, _ in pairs(cache[provider_name]) do
          model_names[short_name] = true
        end
      end

      for short_name, _ in pairs(model_names) do
        table.insert(result, provider_name .. "/" .. short_name)
      end
    end
  end

  table.sort(result)
  return result
end

--- @param callback fun(results: table<string, { ok: boolean, count: integer?, err: string? }>)
function M.refresh(callback)
  local results = {}
  local pending = 0

  for _, spec in pairs(providers) do
    if spec.discover then
      pending = pending + 1
    end
  end

  if pending == 0 then
    callback(results)
    return
  end

  for provider_name, spec in pairs(providers) do
    if spec.discover then
      spec.discover(function(entries, err)
        if entries then
          cache[provider_name] = entries
          results[provider_name] = { ok = true, count = vim.tbl_count(entries) }
        else
          results[provider_name] = { ok = false, err = err or "unknown error" }
        end
        pending = pending - 1
        if pending == 0 then
          save_cache()
          callback(results)
        end
      end)
    end
  end
end

--- @return string[]
function M.list_authorizers()
  local result = {}
  for name, spec in pairs(providers) do
    if spec.authorize then
      table.insert(result, name)
    end
  end
  table.sort(result)
  return result
end

--- @param models_config table<string, sia.config.ModelOptions>
--- @param providers_config table<string, sia.provider.ProviderSpec|boolean>
function M.bootstrap(models_config, providers_config)
  providers = {}
  setup_overrides = {}

  for _, mod_name in ipairs(PROVIDERS) do
    local ok, mod = pcall(require, "sia.provider." .. mod_name)
    if ok and mod and mod.spec then
      M.register(mod_name, mod.spec)
    end
  end

  for name, provider_config in pairs(providers_config or {}) do
    if provider_config == false then
      M.disable(name)
    elseif type(provider_config) == "table" then
      M.register(name, provider_config)
    end

    for provider_name, model_overrides in pairs(models_config or {}) do
      setup_overrides[provider_name] = setup_overrides[provider_name] or {}
      for model_name, override in pairs(model_overrides) do
        setup_overrides[provider_name][model_name] = override
      end
    end
  end

  load_cache()
end

return M
