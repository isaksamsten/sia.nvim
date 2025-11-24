local utils = require("sia.utils")
local tool_utils = require("sia.tools.utils")
local history = require("sia.history")

return tool_utils.new_tool({
  name = "history",
  read_only = true,
  system_prompt = [[Access past conversation history with three modes:

**view_toc** - Browse all saved conversations
- Lists all past conversations with their table of contents
- Shows conversation names, dates, and topic sections
- Use this to discover what past conversations are available

**view** - Read specific messages from a past conversation
- Retrieve exact messages by their index numbers
- Useful when you know which conversation and messages you need
- Parameters: filename (from view_toc), indices (array of message numbers)

**search** - Semantic search across all past conversations
- Find relevant past messages using natural language queries
- Returns messages most similar to your search query
- Only searches conversations that have embeddings enabled
- Parameters: query (your search text), top_k (max results, default 10), threshold
(minimum similarity 0-1, default 0.7)

Use this tool to:
- Reference solutions from past conversations
- Find how similar problems were solved before
- Build on previous work without repeating explanations
- Learn from past mistakes or successful approaches]],
  message = function(args)
    if args.mode == "view_toc" then
      return "Listing all conversation history table of contents..."
    elseif args.mode == "view" then
      return "Viewing messages from history..."
    elseif args.mode == "search" then
      return string.format("Searching history for: %s", args.query or "")
    end
    return "Accessing conversation history..."
  end,
  description = "Access conversation history with search, view, and view_toc modes",
  parameters = {
    mode = {
      type = "string",
      description = "Operation mode: 'search', 'view', or 'view_toc'",
      enum = { "search", "view", "view_toc" },
    },
    query = {
      type = "string",
      description = "Search query (required for search mode)",
    },
    top_k = {
      type = "integer",
      description = "Number of search results to return (optional, default: 10)",
    },
    threshold = {
      type = "number",
      description = "Minimum similarity score 0-1 (optional, default: 0.7). Higher values return only very similar results.",
    },
    filename = {
      type = "string",
      description = "History filename (required for view mode)",
    },
    indices = {
      type = "array",
      description = "Array of message indices to retrieve (required for view mode)",
      items = { type = "integer" },
    },
  },
  auto_apply = function(args, _)
    -- view_toc and view don't require user interaction
    if args.mode == "view_toc" or args.mode == "view" then
      return 1
    end
    return nil
  end,
  required = { "mode" },
}, function(args, conversation, callback, opts)
  local root = utils.detect_project_root(vim.fn.getcwd())
  local history_dir = vim.fs.joinpath(root, ".sia", "history")

  if args.mode == "view_toc" then
    -- List all TOCs from all history files
    local all_history = history.get_history(history_dir)

    if #all_history == 0 then
      callback({
        content = { "No conversation history found in .sia/history directory." },
        display_content = { "📚 No history found" },
      })
      return
    end

    local output = { "Conversation History Table of Contents", "" }
    for _, hist in ipairs(all_history) do
      local content = hist.content
      table.insert(output, string.format("File: %s", hist.filename))
      table.insert(output, string.format("Name: %s", content.name))
      table.insert(output, string.format("Created: %s", content.created_at))
      table.insert(output, string.format("Model: %s", content.model))
      table.insert(output, "")

      if #content.toc > 0 then
        table.insert(output, "Table of Contents:")
        for i, section in ipairs(content.toc) do
          table.insert(
            output,
            string.format(
              "  %d. %s (messages %d-%d)",
              i,
              section.title,
              section.start_index,
              section.end_index
            )
          )
          table.insert(output, string.format("     %s", section.summary))
        end
      else
        table.insert(output, "No table of contents available.")
      end
      table.insert(output, "")
      table.insert(output, "")
    end

    callback({
      content = output,
      display_content = {
        string.format("📚 Listed %d conversation(s)", #all_history),
      },
    })
  elseif args.mode == "view" then
    if not args.filename then
      callback({
        content = { "Error: filename parameter is required for view mode" },
        display_content = { "❌ Missing filename" },
        kind = "failed",
      })
      return
    end

    if not args.indices or type(args.indices) ~= "table" or #args.indices == 0 then
      callback({
        content = {
          "Error: indices parameter is required for view mode and must be a non-empty array",
        },
        display_content = { "❌ Missing or invalid indices" },
        kind = "failed",
      })
      return
    end

    local messages =
      history.get_messages_by_indices(history_dir, args.filename, args.indices)

    if #messages == 0 then
      callback({
        content = {
          string.format(
            "No messages found in %s for indices: %s",
            args.filename,
            vim.inspect(args.indices)
          ),
        },
        display_content = { "❌ No messages found" },
        kind = "failed",
      })
      return
    end

    local output = {
      string.format("Messages from %s", args.filename),
      string.format("Retrieved %d message(s)", #messages),
      "",
    }

    for _, msg in ipairs(messages) do
      table.insert(output, string.format("[%d] %s:", msg.index, msg.role))
      table.insert(output, msg.content)
      table.insert(output, "")
      table.insert(output, "")
    end

    callback({
      content = output,
      display_content = {
        string.format("📖 Retrieved %d message(s)", #messages),
      },
    })
  elseif args.mode == "search" then
    if not args.query or args.query == "" then
      callback({
        content = { "Error: query parameter is required for search mode" },
        display_content = { "❌ Missing query" },
        kind = "failed",
      })
      return
    end

    local embedding_model_name = require("sia.config").options.defaults.embedding_model
    if not embedding_model_name then
      callback({
        content = {
          "Error: No embedding model configured.",
          "History search requires embeddings to be enabled.",
        },
        display_content = { "❌ No embedding model" },
        kind = "failed",
      })
      return
    end

    local embedding_model = require("sia.model").resolve(embedding_model_name)
    local prompt = string.format("Search conversation history for: %s", args.query)
    opts.user_input(prompt, {
      on_accept = function()
        local top_k = args.top_k or 10
        local threshold = args.threshold or 0.3

        history.search_messages(history_dir, args.query, embedding_model, {
          top_k = top_k,
          threshold = threshold,
          callback = function(results)
            if #results == 0 then
              callback({
                content = {
                  string.format("No matching messages found for query: %s", args.query),
                  "",
                },
                display_content = { "🔍 No matches found" },
              })
              return
            end

            local output = {
              string.format("Search Results for: %s", args.query),
              string.format("Found %d matching message(s)", #results),
              "",
            }

            for i, result in ipairs(results) do
              local msg = result.message
              table.insert(output, string.format("--- Result %d ---", i))
              table.insert(output, string.format("File: %s", result.filename))
              table.insert(output, string.format("[%d] %s:", msg.index, msg.role))
              table.insert(output, msg.content)
              table.insert(output, "")
            end

            callback({
              content = output,
              display_content = {
                string.format("🔍 Found %d match(es) for '%s'", #results, args.query),
              },
            })
          end,
        })
      end,
    })
  else
    callback({
      content = {
        string.format("Error: Invalid mode '%s'", args.mode or "nil"),
        "Valid modes are: 'search', 'view', 'view_toc'",
      },
      display_content = { "❌ Invalid mode" },
      kind = "failed",
    })
  end
end)
