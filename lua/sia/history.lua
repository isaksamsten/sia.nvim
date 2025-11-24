local assistant = require("sia.assistant")

local HISTORY_VERSION = "1.0"
local MAX_METADATA_CHARS_PER_MESSAGE = 1000
local M = {}

--- @class sia.History
--- @field version string
--- @field name string
--- @field created_at string
--- @field model string
--- @field embedding_model string?
--- @field toc sia.history.TOC
--- @field messages sia.history.Message[]

--- @class sia.history.TOC
--- @field title string
--- @field summary string
--- @field start_index integer
--- @field end_index integer

--- @class sia.history.Message
--- @field index integer
--- @field role string
--- @field content string
--- @field embedding number[]?

--- Extract messages to send to the metadata model for naming/TOC
--- For now, keep it simple: use prepared messages and include only
--- user/assistant roles with string content.
--- @param conversation sia.Conversation
--- @return sia.history.Message[]
local function extract_history_messages(conversation)
  local prepared = conversation:prepare_messages()
  local filtered = {}

  local index = 1
  for _, msg in ipairs(prepared) do
    if
      (msg.role == "user" or msg.role == "assistant")
      and type(msg.content) == "string"
    then
      table.insert(filtered, { index = index, role = msg.role, content = msg.content })
      index = index + 1
    end
  end

  return filtered
end

local METADATA_SYSTEM_PROMPT = [[You are a tool that generates save metadata for an
conversation. You receive the conversation as a numbered list of messages.
Each line starts with "[index] role: content" where index is 1-based. Your job is to
propose a concise name and a table of contents (TOC) for this conversation. The TOC
should split the conversation into 2-10 sections, each with: title, summary,
start_index, end_index.]]

local METADATA_SCHEMA = {
  type = "object",
  properties = {
    name = {
      type = "string",
      description = "A concise name for the conversation",
    },
    toc = {
      type = "array",
      description = "Table of contents with 2-10 sections",
      items = {
        type = "object",
        properties = {
          title = { type = "string", description = "Section title" },
          summary = { type = "string", description = "Brief section summary" },
          start_index = {
            type = "integer",
            description = "Starting message index (1-based)",
          },
          end_index = {
            type = "integer",
            description = "Ending message index (1-based)",
          },
        },
        required = { "title", "summary", "start_index", "end_index" },
        additionalProperties = false,
      },
    },
  },
  required = { "name", "toc" },
  additionalProperties = false,
}

--- Build the user message content from extracted messages.
--- @param messages { index: integer, role: string, content: string }[]
--- @return string
local function build_user_message(messages)
  local lines = { "Here are the messages:", "" }

  for _, m in ipairs(messages) do
    local single_line_content = m.content:gsub("\n", " ")
    if #single_line_content > MAX_METADATA_CHARS_PER_MESSAGE then
      single_line_content = single_line_content:sub(1, MAX_METADATA_CHARS_PER_MESSAGE)
        .. " [truncated...]"
    end
    table.insert(
      lines,
      string.format("[%d] %s: %s", m.index, m.role, single_line_content)
    )
  end

  return table.concat(lines, "\n")
end

--- Construct the Lua table that will eventually be written to disk.
--- This calls the metadata model via assistant.fetch_response to obtain
--- the conversation name and TOC, and then returns a Lua table with
--- basic fields filled in. For now, we ignore writing to disk.
---
--- NOTE: This function is asynchronous; the callback will be invoked
--- once the metadata model responds.
---
--- @param conversation sia.Conversation
--- @param opts {callback: fun(result: sia.History), embedding_model: sia.Model?}
function M.new_history(conversation, opts)
  local meta_messages = extract_history_messages(conversation)
  local user_content = build_user_message(meta_messages)

  local fast_model = { name = "openai/gpt-5.1" }
  local model = vim.tbl_extend("force", fast_model, {
    response_format = {
      type = "json_schema",
      json_schema = {
        name = "conversation_metadata",
        strict = true,
        schema = METADATA_SCHEMA,
      },
    },
  })

  local Conversation = require("sia.conversation").Conversation

  local metadata_conv = Conversation:new({
    model = model,
    system = {
      {
        role = "system",
        content = METADATA_SYSTEM_PROMPT,
      },
    },
    instructions = {
      { role = "user", content = user_content },
    },
  }, nil)

  assistant.fetch_response(metadata_conv, function(response)
    local name = conversation.name or ""
    local toc = {}

    if type(response) == "string" and response ~= "" then
      local ok, decoded = pcall(vim.json.decode, response, {
        luanil = { object = true },
      })
      if ok and type(decoded) == "table" then
        if type(decoded.name) == "string" then
          name = decoded.name
        end
        if type(decoded.toc) == "table" then
          toc = decoded.toc
        end
      end
    end

    --- @type sia.History
    local result = {
      version = HISTORY_VERSION,
      name = name,
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      model = conversation.model:name(),
      embedding_model = opts.embedding_model and opts.embedding_model:name() or nil,
      toc = toc,
      messages = meta_messages,
    }

    if opts.embedding_model then
      local contents = {}
      for _, message in ipairs(result.messages) do
        table.insert(contents, message.content)
      end

      assistant.fetch_embedding(contents, opts.embedding_model, function(embeddings)
        if embeddings then
          for i, message in ipairs(result.messages) do
            message.embedding = embeddings[i]
          end
        end
        opts.callback(result)
      end)
    else
      opts.callback(result)
    end
  end)
end

--- Load a single history file from disk
--- @param history_dir string
--- @param filename string The filename (not full path)
--- @return sia.History? history The parsed history object, or nil on error
local function load_history_file(history_dir, filename)
  local filepath = vim.fs.joinpath(history_dir, filename)
  local content = vim.fn.readfile(filepath)
  local ok, history = pcall(vim.json.decode, table.concat(content, " "), {
    luanil = { object = true },
  })

  if ok and type(history) == "table" then
    return history
  end

  return nil
end

--- Validate that a history object has all required fields
--- @param history table The history object to validate
--- @return boolean
local function validate_history(history)
  if type(history) ~= "table" then
    return false
  end

  if type(history.version) ~= "string" or history.version ~= HISTORY_VERSION then
    return false
  end
  if type(history.name) ~= "string" then
    return false
  end
  if type(history.created_at) ~= "string" or history.created_at == "" then
    return false
  end
  if type(history.model) ~= "string" or history.model == "" then
    return false
  end

  if history.embedding_model ~= nil and type(history.embedding_model) ~= "string" then
    return false
  end

  if type(history.toc) ~= "table" then
    return false
  end

  if type(history.messages) ~= "table" then
    return false
  end

  for _, message in ipairs(history.messages) do
    if type(message) ~= "table" then
      return false
    end
    if type(message.index) ~= "number" then
      return false
    end
    if type(message.role) ~= "string" or message.role == "" then
      return false
    end
    if type(message.content) ~= "string" then
      return false
    end
    if message.embedding ~= nil and type(message.embedding) ~= "table" then
      return false
    end
  end

  return true
end

--- Get table of contents for all saved history files
--- @return {filename: string, content: sia.History}[]
function M.get_history(history_dir)
  local stat = vim.loop.fs_stat(history_dir)
  if not stat or stat.type ~= "directory" then
    return {}
  end

  local handle = vim.loop.fs_scandir(history_dir)
  if not handle then
    return {}
  end
  --- @type {filename: string, content: sia.History}
  local results = {}
  local name, type = vim.loop.fs_scandir_next(handle)

  while name do
    if type == "file" and name:match("%.json$") then
      local history = load_history_file(history_dir, name)
      if history and validate_history(history) then
        table.insert(results, { filename = name, content = history })
      end
    end
    name, type = vim.loop.fs_scandir_next(handle)
  end

  table.sort(results, function(a, b)
    return a.content.created_at > b.content.created_at
  end)

  return results
end

--- Get messages by index from a specific history file
--- @param history_dir string
--- @param filename string The history filename
--- @param indices integer[] List of message indices (1-based)
--- @return sia.history.Message[]
function M.get_messages_by_indices(history_dir, filename, indices)
  local history = load_history_file(history_dir, filename)
  if not history then
    return {}
  end

  local results = {}
  local index_set = {}
  for _, idx in ipairs(indices) do
    index_set[idx] = true
  end

  for _, message in ipairs(history.messages) do
    if index_set[message.index] then
      table.insert(results, message)
    end
  end

  return results
end

--- @class sia.history.SearchResult
--- @field filename string The history filename
--- @field message sia.history.Message The matching message
--- @field score number Similarity score (0-1)

--- Search for messages across all history files using embedding similarity
--- @param query string The search query
--- @param embedding_model sia.Model The model to use for embedding the query
--- @param opts {top_k: integer?, threshold: number?, callback: fun(results: {filename:string, message: sia.history.Message}[])}
function M.search_messages(history_dir, query, embedding_model, opts)
  opts = opts or {}
  local top_k = opts.top_k or 10
  local threshold = opts.threshold

  assistant.fetch_embedding({ query }, embedding_model, function(query_embeddings)
    if not query_embeddings or #query_embeddings == 0 then
      opts.callback({})
      return
    end

    local embedding = query_embeddings[1]

    local all_history = M.get_history(history_dir)

    --- @type {filename:string, message: sia.history.Message}[]
    local all_targets = {}

    --- @type number[][]
    local embeddings = {}

    for _, history in ipairs(all_history) do
      local content = history.content
      if content.embedding_model == embedding_model:name() then
        for _, message in ipairs(content.messages) do
          if message.embedding then
            table.insert(
              all_targets,
              { filename = history.filename, message = message }
            )
            table.insert(embeddings, message.embedding)
          end
        end
      end
    end

    if #all_targets == 0 then
      opts.callback({})
      return
    end

    require("sia.similarity").find_similar(embedding, embeddings, {
      top_k = top_k,
      threshold = threshold,
      callback = function(similar_results)
        local results = {}
        for _, result in ipairs(similar_results) do
          local target = all_targets[result.index]
          table.insert(results, target)
        end

        opts.callback(results)
      end,
    })
  end)
end

return M
