local tool_utils = require("sia.tools.utils")

local FAILED_FETCH = "❌ Failed to fetch paper"
local FAILED_TO_ACCESS = "❌ Failed to access CORE API"

return tool_utils.new_tool({
  name = "paper",
  description = "Retrieve a specific research paper by its CORE ID",
  read_only = true,
  is_available = function()
    return vim.fn.executable("curl") == 1 and os.getenv("CORE_API_KEY") ~= nil
  end,
  message = function(args)
    local parts = { "Retrieving paper with ID: " .. args.id }
    if args.includeFullText then
      table.insert(parts, "including full text")
    end
    return table.concat(parts, " ")
  end,
  system_prompt = [[
You have access to a tool that retrieves individual research papers from the CORE academic database using their unique CORE ID.

This tool allows you to:
- Get detailed metadata for a specific paper (title, authors, abstract, publication info)
- Optionally retrieve full text content when available
- Access DOI, publication dates, and other bibliographic information

Usage notes:
- Requires a valid CORE ID (usually obtained from search results)
- Full text retrieval may take longer and should only be used when specifically needed
- Respects copyright - provides access to open access content only
- Some papers may not have full text available even if requested
]],
  required = { "id" },
  parameters = {
    id = {
      type = "string",
      description = "CORE ID of the paper to retrieve",
    },
    includeFullText = {
      type = "boolean",
      description = "Include full text content if available (default: false)",
    },
  },
}, function(args, _, callback, opts)
  -- Validate ID
  if not args.id or args.id == "" then
    callback({
      content = { "Error: Paper ID is required" },
      display_content = { "❌ Error: Paper ID is required" },
    })
    return
  end

  opts.user_input("Retrieve paper with ID: " .. args.id, {
    on_accept = function()
      local url = string.format("https://api.core.ac.uk/v3/works/%s", args.id)

      local curl_args = { "curl", "-X", "GET" }

      local api_key = os.getenv("CORE_API_KEY")
      if api_key then
        table.insert(curl_args, "-H")
        table.insert(curl_args, "Authorization: Bearer " .. api_key)
      end

      table.insert(curl_args, url)

      -- Execute request
      local result = vim.system(curl_args, { text = true }):wait()

      if result.code ~= 0 then
        local error_msg = string.format(
          "Failed to fetch paper (curl exit code: %d). Error: %s",
          result.code,
          result.stderr or "Unknown error"
        )
        callback({
          content = { FAILED_TO_ACCESS .. ": " .. error_msg },
          display_content = { FAILED_TO_ACCESS },
        })
        return
      end

      -- Parse JSON response
      local ok, json =
        pcall(vim.json.decode, result.stdout, { luanil = { object = true } })
      if not ok then
        callback({
          content = { FAILED_FETCH .. ": Failed to parse API response - " },
          display_content = { FAILED_FETCH },
        })
        return
      end

      if json.message then
        local error_msg = "API Error: " .. json.message
        if string.find(json.message:lower(), "not found") then
          error_msg = string.format("Paper with ID '%s' not found", args.id)
        end
        callback({
          content = { error_msg },
          display_content = { "❌ " .. error_msg },
        })
        return
      end

      local content = {}
      local display_content = {}

      local title = json.title and string.gsub(json.title, "\n", " "):gsub("%s+", " ")
        or "Untitled"
      table.insert(content, "# " .. title)
      table.insert(display_content, "📄 Read '" .. title .. "'")

      table.insert(content, string.format("**CORE ID:** %s", args.id))
      if json.authors and #json.authors > 0 then
        local author_names = {}
        for _, author in ipairs(json.authors) do
          if author.name then
            table.insert(author_names, author.name)
          end
        end
        if #author_names > 0 then
          table.insert(content, "**Authors:** " .. table.concat(author_names, ", "))
        end
      end

      if json.yearPublished then
        table.insert(content, "**Year:** " .. json.yearPublished)
      end

      if json.publisher then
        table.insert(content, "**Publisher:** " .. json.publisher)
      end

      if json.doi then
        table.insert(content, "**DOI:** " .. json.doi)
      end

      if json.documentType and #json.documentType > 0 then
        table.insert(
          content,
          "**Document Type:** " .. table.concat(json.documentType, ", ")
        )
      end

      if json.abstract then
        local abstract = string.gsub(json.abstract, "\n", " "):gsub("%s+", " ")
        if #abstract > 0 then
          table.insert(content, "")
          table.insert(content, "## Abstract")
          table.insert(content, abstract)
        end
      end

      if args.includeFullText and json.fullText then
        table.insert(content, "")
        table.insert(content, "## Full Text")
        local fullText = vim.split(json.fullText, "\n")
        for _, line in ipairs(fullText) do
          table.insert(content, line)
        end
      elseif not json.fullText then
        table.insert(content, "")
        table.insert(content, "*Full text not available for this paper*")
      end

      if json.downloadUrl then
        table.insert(content, "")
        table.insert(content, "**Download URL:** " .. json.downloadUrl)
      end

      callback({
        content = { table.concat(content, "\n") },
        display_content = { table.concat(display_content, "\n") },
      })
    end,
  })
end)
