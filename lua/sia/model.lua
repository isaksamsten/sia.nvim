local M = {}

--- @class sia.Model
--- @field name string
--- @field api_name string
--- @field provider_name string
--- @field config table
--- @field context_window integer?
--- @field response_format table?
--- @field pricing {input: number, output: number}?
--- @field cache_multiplier {read: number, write: number}?
--- @field options table<string, any>
--- @field support sia.config.Support
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
  obj.name = model_config.name
  obj.config = vim.deepcopy(model_config)
  obj.provider_name = model_spec[1]
  obj.api_name = model_spec[2]
  obj.support = setmetatable({}, {
    __index = function(_, key)
      return model_spec.support ~= nil and model_spec.support[key] or false
    end,
  })
  obj.context_window = model_spec.context_window
  obj.response_format = model_spec.response_format
  obj.pricing = model_spec.pricing
  obj.cache_multiplier = model_spec.cache_multiplier
  obj.options =
    vim.tbl_extend("force", model_spec.options or {}, model_config.options or {})
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
