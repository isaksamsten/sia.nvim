local M = {}

--- @class sia.ui.ModelEntry
--- @field tag string
--- @field id any
--- @field obj any

--- @class sia.ui.ModelSource
--- @field tag string
--- @field items any[]|fun():any[]
--- @field id fun(obj: any):any
--- @field refresh (fun(old: any[]):boolean)?

--- @class sia.ui.ListModelOpts
--- @field sources sia.ui.ModelSource[]
--- @field sort (fun(a: sia.ui.ModelEntry, b: sia.ui.ModelEntry): boolean)?

--- @class sia.ui.ListModel
--- @field private sources sia.ui.ModelSource[]
--- @field private sort_fn (fun(a: sia.ui.ModelEntry, b: sia.ui.ModelEntry): boolean)?
--- @field private entries sia.ui.ModelEntry[]
--- @field private cache table<string, {items: any[], id: string}>
local ListModel = {}
ListModel.__index = ListModel

--- Create a new source-backed list model.
--- Sources are scanned on first access and re-scanned when any source length changes.
--- @param opts sia.ui.ListModelOpts
--- @return sia.ui.ListModel
function ListModel.new(opts)
  local self = setmetatable({
    sources = opts.sources or {},
    sort_fn = opts.sort,
    entries = {},
    cache = {},
  }, ListModel)
  self:rebuild()
  return self
end

--- Check whether any source list changed length since last rebuild.
--- @return boolean
function ListModel:dirty()
  for _, src in ipairs(self.sources) do
    local items = type(src.items) == "table" and src.items or src.items()
    local cache = self.cache[src.tag]
    if
      not cache
      or #items ~= #cache.items
      or tostring(items) ~= cache.id
      or (src.refresh and src.refresh(cache.items))
    then
      return true
    end
  end
  return false
end

--- Rebuild the entries list from all sources, then sort.
function ListModel:rebuild()
  self.entries = {}
  for _, src in ipairs(self.sources) do
    local items = type(src.items) == "table" and src.items or src.items() --[[@as any[]]
    self.cache[src.tag] = { items = items, id = tostring(items) }
    for _, obj in ipairs(items) do
      local id = src.id(obj)
      table.insert(self.entries, { tag = src.tag, id = id, obj = obj })
    end
  end
  if self.sort_fn then
    table.sort(self.entries, self.sort_fn)
  end
end

function ListModel:refresh()
  if self:dirty() then
    self:rebuild()
  end
end

--- @return integer
function ListModel:count()
  self:refresh()
  return #self.entries
end

--- @param tag string
--- @param id any
--- @return sia.ui.ModelEntry?
function ListModel:get(tag, id)
  self:refresh()
  for _, entry in ipairs(self.entries) do
    if entry.tag == tag and entry.id == id then
      return entry
    end
  end
  return nil
end

--- @param tag string
--- @param id any
--- @return boolean
function ListModel:has(tag, id)
  return self:get(tag, id) ~= nil
end

--- Iterate entries in sorted order (refreshes first).
--- @return fun(): integer?
--- @return sia.ui.ModelEntry?
--- @return integer
function ListModel:iter()
  self:refresh()
  return ipairs(self.entries)
end

local DEFAULT_SPINNER = { "", "", "", "", "", "" }
local EXPANDED_MARKER = "▾"
local COLLAPSED_MARKER = "▸"

--- @class sia.ui.LineInfo
--- @field hl_group string?
--- @field col integer?
--- @field end_col integer?
--- @field line_hl_group string?

--- @class sia.ui.RenderSpec
--- @field icon string
--- @field label string
--- @field suffix string?
--- @field hl string?
--- @field running boolean?
--- @field actions table<string, fun(): any>?
--- @field details (fun(d: sia.ui.DetailBuilder))?

--- @class sia.ui.DetailBuilder
--- @field details sia.ui.ListDetail[]
local DetailBuilder = {}
DetailBuilder.__index = DetailBuilder

--- @class sia.ui.ListDetail
--- @field type "line"|"detail"|"block"
--- @field text string?
--- @field label string?
--- @field value string?
--- @field header string?
--- @field values string[]?
--- @field hl_group string?

function DetailBuilder.new()
  return setmetatable({ details = {} }, DetailBuilder)
end

--- @param text string
--- @param hl_group string? highlight group (default: "SiaStatusMuted")
function DetailBuilder:line(text, hl_group)
  table.insert(self.details, {
    type = "line",
    text = text,
    hl_group = hl_group,
  })
end

--- @param label string
--- @param value string?
--- @param hl_group string? highlight for value (default: "SiaStatusValue")
function DetailBuilder:detail(label, value, hl_group)
  if not value or value == "" then
    return
  end
  table.insert(self.details, {
    type = "detail",
    label = label,
    value = value,
    hl_group = hl_group,
  })
end

--- @param header string
--- @param values string[]
function DetailBuilder:block(header, values)
  if not values or #values == 0 then
    return
  end
  table.insert(self.details, {
    type = "block",
    header = header,
    values = values,
  })
end

--- @param detail sia.ui.ListDetail
--- @return string[]
--- @return sia.ui.LineInfo[][]
local function render_line_detail(detail)
  local text = "    " .. (detail.text or "")
  local hl_group = detail.hl_group or "SiaStatusMuted"
  return { text }, {
    {
      { line_hl_group = hl_group },
      { col = 4, end_col = #text, hl_group = hl_group },
    },
  }
end

--- @param detail sia.ui.ListDetail
--- @return string[]
--- @return sia.ui.LineInfo[][]
local function render_kv_detail(detail)
  local label = detail.label or ""
  local value = detail.value or ""
  local text = string.format("    %s: %s", label, value)
  local label_end = 4 + #label + 1
  local value_start = label_end + 1
  local hl_group = detail.hl_group or "SiaStatusValue"
  return { text }, {
    {
      { line_hl_group = "SiaStatusMuted" },
      { col = 4, end_col = label_end, hl_group = "SiaStatusLabel" },
      { col = value_start, end_col = value_start + #value, hl_group = hl_group },
    },
  }
end

--- @param detail sia.ui.ListDetail
--- @return string[]
--- @return sia.ui.LineInfo[][]
local function render_block_detail(detail)
  local header = detail.header or ""
  local values = detail.values or {}
  local lines = {}
  local highlights = {}

  local header_text = "    " .. header
  table.insert(lines, header_text)
  table.insert(highlights, {
    { line_hl_group = "SiaStatusMuted" },
    { col = 4, end_col = 4 + #header, hl_group = "SiaStatusLabel" },
  })

  for _, value in ipairs(values) do
    local value_text = "      " .. value
    table.insert(lines, value_text)
    table.insert(highlights, {
      { col = 6, end_col = 6 + #value, hl_group = "SiaStatusCode" },
    })
  end

  return lines, highlights
end

--- @param detail sia.ui.ListDetail
--- @return string[]
--- @return sia.ui.LineInfo[][]
local function render_detail(detail)
  if detail.type == "line" then
    return render_line_detail(detail)
  elseif detail.type == "detail" then
    return render_kv_detail(detail)
  elseif detail.type == "block" then
    return render_block_detail(detail)
  end
  return {}, {}
end

--- @param tag string
--- @param id any
--- @return string
local function expand_key(tag, id)
  return tag .. ":" .. tostring(id)
end

--- @class sia.ui.ListView
--- @field model sia.ui.ListModel
--- @field private render_fn fun(tag: string, id: any, obj: any): sia.ui.RenderSpec?
--- @field private expanded table<string, boolean>
--- @field private expandable boolean
--- @field private default_expanded boolean
--- @field private spinner string[]
--- @field private spinner_frame integer
--- @field private line_to_entry table<integer, sia.ui.ModelEntry>
--- @field private line_to_spec table<integer, sia.ui.RenderSpec>
--- @field private summary_lines table<integer, boolean>
--- @field private max_line integer
--- @field private empty_message string
--- @field has_running boolean
local ListView = {}
ListView.__index = ListView

--- @class sia.ui.ListViewOpts
--- @field render fun(tag: string, id: any, obj: any): sia.ui.RenderSpec?
--- @field default_expanded boolean?
--- @field expandable boolean?
--- @field spinner string[]?
--- @field empty_message string?

--- @param model sia.ui.ListModel
--- @param opts sia.ui.ListViewOpts
--- @return sia.ui.ListView
function ListView.new(model, opts)
  local obj = setmetatable({
    model = model,
    render_fn = opts.render,
    expanded = {},
    expandable = true,
    default_expanded = opts.default_expanded or false,
    spinner = opts.spinner or DEFAULT_SPINNER,
    spinner_frame = 1,
    line_to_entry = {},
    line_to_spec = {},
    summary_lines = {},
    max_line = 0,
    empty_message = opts.empty_message or "No items",
    has_running = false,
  }, ListView)
  if opts.expandable == false then
    obj.expandable = false
    obj.default_expanded = true
  end
  return obj
end

--- @param tag string
--- @param id any
--- @return boolean
function ListView:is_expanded(tag, id)
  if not self.expandable then
    return false
  end
  local key = expand_key(tag, id)
  local v = self.expanded[key]
  if v == nil then
    return self.default_expanded
  end
  return v
end

function ListView:toggle(line)
  if not self.expandable then
    return
  end

  local entry = self.line_to_entry[line]
  if not entry then
    return
  end
  local key = expand_key(entry.tag, entry.id)
  local current = self.expanded[key]
  if current == nil then
    self.expanded[key] = not self.default_expanded
  else
    self.expanded[key] = not current
  end
end

--- @param tag string
--- @param id any
function ListView:expand(tag, id)
  if not self.expandable then
    return
  end
  self.expanded[expand_key(tag, id)] = true
end

--- @param tag string
--- @param id any
function ListView:collapse(tag, id)
  if not self.expandable then
    return
  end
  self.expanded[expand_key(tag, id)] = false
end

function ListView:expand_all()
  if not self.expandable then
    return
  end
  for _, entry in self.model:iter() do
    self.expanded[expand_key(entry.tag, entry.id)] = true
  end
end

function ListView:collapse_all()
  if not self.expandable then
    return
  end
  for _, entry in self.model:iter() do
    self.expanded[expand_key(entry.tag, entry.id)] = false
  end
end

function ListView:tick()
  if self.has_running then
    self.spinner_frame = (self.spinner_frame % #self.spinner) + 1
  else
    self.spinner_frame = 1
  end
end

--- @param line integer 1-based line number
--- @return string? tag
--- @return any? id
--- @return any? obj
function ListView:item_at(line)
  local entry = self.line_to_entry[line]
  if not entry then
    return nil, nil, nil
  end
  return entry.tag, entry.id, entry.obj
end

--- @param line integer
--- @param name string
--- @return boolean
function ListView:has_action(line, name)
  local spec = self.line_to_spec[line]
  return spec ~= nil and spec.actions ~= nil and spec.actions[name] ~= nil
end

--- @param line integer
--- @param name string
--- @return any
function ListView:trigger(line, name)
  local spec = self.line_to_spec[line]
  if not spec or not spec.actions or not spec.actions[name] then
    return nil
  end
  return spec.actions[name]()
end

--- @param line integer
--- @param direction 1|-1
--- @return integer?
function ListView:find_item(line, direction)
  local current_entry = self.line_to_entry[line]
  local l = line + direction
  while l >= 1 and l <= self.max_line do
    if self.summary_lines[l] then
      local entry = self.line_to_entry[l]
      if not current_entry or entry ~= current_entry then
        return l
      end
    end
    l = l + direction
  end
  return nil
end

function ListView:gc()
  local alive = {}
  for _, entry in self.model:iter() do
    alive[expand_key(entry.tag, entry.id)] = true
  end
  for key in pairs(self.expanded) do
    if not alive[key] then
      self.expanded[key] = nil
    end
  end
end

--- @return string[] lines
--- @return sia.ui.LineInfo[][]
function ListView:render()
  local lines = {}
  local highlights = {}
  self.line_to_entry = {}
  self.line_to_spec = {}
  self.summary_lines = {}
  self.has_running = false

  for _, entry in self.model:iter() do
    local spec = self.render_fn(entry.tag, entry.id, entry.obj)
    if not spec then
      goto continue
    end

    local is_expanded_entry = self.expanded[expand_key(entry.tag, entry.id)]
    if is_expanded_entry == nil then
      is_expanded_entry = self.default_expanded
    end

    local running = spec.running or false
    if running then
      self.has_running = true
    end

    local has_details = spec.details ~= nil
    local marker = ""
    if has_details and self.expandable then
      marker = is_expanded_entry and EXPANDED_MARKER or COLLAPSED_MARKER
    end
    local icon = running and self.spinner[self.spinner_frame] or spec.icon

    local parts = { "  " }
    if has_details and self.expandable then
      table.insert(parts, marker)
      table.insert(parts, " ")
    end
    table.insert(parts, icon)
    table.insert(parts, " ")
    table.insert(parts, spec.label)
    if spec.suffix and spec.suffix ~= "" then
      table.insert(parts, " ")
      table.insert(parts, spec.suffix)
    end
    local summary_text = table.concat(parts)

    local hl_list = {}
    if spec.hl then
      table.insert(hl_list, { line_hl_group = spec.hl })
    end
    if has_details then
      table.insert(
        hl_list,
        { col = 2, end_col = 2 + #marker, hl_group = "SiaStatusMuted" }
      )
    end
    if spec.suffix and spec.suffix ~= "" then
      local suffix_start = #summary_text - #spec.suffix
      table.insert(
        hl_list,
        { col = suffix_start, end_col = #summary_text, hl_group = "SiaStatusMuted" }
      )
    end

    table.insert(lines, summary_text)
    table.insert(highlights, hl_list)
    local line_num = #lines
    self.line_to_entry[line_num] = entry
    self.line_to_spec[line_num] = spec
    self.summary_lines[line_num] = true

    if is_expanded_entry and has_details then
      local builder = DetailBuilder.new()
      spec.details(builder)
      for _, detail in ipairs(builder.details) do
        local detail_lines, detail_hls = render_detail(detail)
        for i, dl in ipairs(detail_lines) do
          table.insert(lines, dl)
          table.insert(highlights, detail_hls[i] or {})
          self.line_to_entry[#lines] = entry
          self.line_to_spec[#lines] = spec
        end
      end
    end

    ::continue::
  end

  self.max_line = #lines

  if #lines == 0 then
    table.insert(lines, self.empty_message)
    table.insert(highlights, {
      { line_hl_group = "SiaStatusMuted" },
      { col = 0, end_col = #self.empty_message, hl_group = "SiaStatusMuted" },
    })
    self.max_line = 1
  end

  return lines, highlights
end

--- @param buf integer
--- @param ns integer
function ListView:apply(buf, ns)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines, highlights = self:render()

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, hl_list in ipairs(highlights) do
    for _, info in ipairs(hl_list) do
      if info.hl_group then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, info.col or 0, {
          hl_group = info.hl_group,
          end_col = info.end_col or 0,
        })
      elseif info.line_hl_group then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
          line_hl_group = info.line_hl_group,
        })
      end
    end
  end
end

M.ListView = ListView
M.DetailBuilder = DetailBuilder
M.ListModel = ListModel

return M
