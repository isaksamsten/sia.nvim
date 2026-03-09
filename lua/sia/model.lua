local M = {}

--- @class sia.Model
--- @field config table
--- @field spec sia.config.ModelSpec|sia.config.EmbeddingSpec
--- @field api_name string
--- @field provider_name string
--- @field params table<string, boolean>
--- @field support table
local Model = {}
Model.__index = Model

--- Create a new Model instance
--- @param model_config table Model config with at least {name:string}
--- @return sia.Model
function Model:new(model_config)
  local config = require("sia.config")

  if not model_config or not model_config.name then
    error("Model config must have a 'name' field")
  end

  --- @type sia.config.ModelSpec
  local model_spec = config.options.models[model_config.name]
  if not model_spec then
    model_spec = config.options.embeddings[model_config.name]
    if not model_spec then
      error(string.format("Unknown model: %s", model_config.name))
    end
  end

  local obj = setmetatable({}, self)
  obj.config = model_config
  obj.spec = model_spec
  obj.provider_name = model_spec[1]
  obj.api_name = model_spec[2]
  obj.support = setmetatable({}, {
    __index = function(_, key)
      return obj.spec.support[key] or false
    end,
  })
  obj.params = setmetatable({}, {
    __index = function(_, key)
      return obj.config[key] or obj.spec[key] or nil
    end,
  })
  return obj
end

--- Resolve a model config (string or table) to a Model instance
--- @param model_config table|string|nil Normalized model config or string name
--- @return sia.Model
function M.resolve(model_config)
  local config = require("sia.config")

  -- If nil, use default model
  if not model_config then
    model_config = config.options.settings.model
  end

  -- If string, normalize it
  if type(model_config) == "string" then
    model_config = { name = model_config }
  end

  return Model:new(model_config)
end

--- Get the model name (e.g., "openai/gpt-4.1")
--- @return string
function Model:name()
  return self.config.name
end

--- Get the provider instance
--- @return sia.config.Provider
function Model:get_provider()
  local config = require("sia.config")
  local provider = config.options.providers[self.provider_name]
  if not provider then
    provider = require("sia.provider.defaults")[self.provider_name]
  end
  return provider
end

return M
