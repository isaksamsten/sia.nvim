local tool_utils = require("sia.tools.utils")
local FAILED_FETCH = "❌ Failed to fetch research papers"
local FAILED_TO_ACCESS = "❌ Failed to access CORE API"

return tool_utils.new_tool({
  name = "search_papers",
  is_available = function()
    return os.getenv("CORE_API_KEY") ~= nil
  end,
  message = function(args)
    return string.format("Searching research papers: %s", args.query)
  end,
  description = "Search for research articles using the CORE API query language",
  system_prompt = [[- Search for research articles using the CORE API with full query language support
- Returns academic papers with titles, authors, abstracts, and publication details
- Use this tool when you need to find academic research, papers, or scholarly articles

Query Language Operators:
  - AND, OR: Logical operators (e.g., "machine learning AND transformers")
  - +, space: Also work as AND
  - (...): Grouping for complex queries
  - field:value: Search specific fields
  - field:"exact phrase": Exact phrase match in field
  - field>value, field>=value, field<value, field<=value: Range queries for numbers/dates
  - _exists_:fieldName: Check if field exists

Key Searchable Fields:
  - title, abstract, fullText: Content fields
  - authors, contributors: People involved
  - doi, arxivId, pubmedId, magId: Identifiers
  - yearPublished: Publication year (use with >, <, >=, <=)
  - publishedDate, acceptedDate, depositedDate: Dates (format: YYYY-MM-DDTHH:MM:SS)
  - documentType: Type (e.g., 'research', 'thesis', 'conference paper', 'book')
  - publisher, dataProviders: Publishing information
  - citationCount, fieldOfStudy: Metadata

Query Examples:
  - title:"attention is all you need"
  - authors:"Geoffrey Hinton" AND yearPublished>=2020
  - (deep learning OR neural networks) AND documentType:thesis
  - machine learning AND _exists_:fullText AND yearPublished>=2015
  - title:transformers AND citationCount>100
  - abstract:retrieval-augmented-generation AND publisher:Nature
  - fieldOfStudy:biology AND documentType:"research article" AND yearPublished>=2020

Usage notes:
  - Returns up to 5 results by default (configurable with limit parameter, max 100)
  - Unquoted terms match any/all words in any order
  - Quoted terms match exact phrases
  - Free text (no field specified) searches across all fields]],
  parameters = {
    query = {
      type = "string",
      description = 'CORE API query using the full query language. Construct queries with field lookups, operators, and ranges. Examples: title:"machine learning" AND yearPublished>=2020, authors:"John Doe" AND _exists_:fullText, (transformers OR attention) AND documentType:thesis',
    },
    offset = {
      type = "integer",
      description = "The offset",
    },
    limit = {
      type = "integer",
      description = "Number of results to return (1-100, default: 5)",
    },
  },
  required = { "query" },
  read_only = true,
}, function(args, _, callback, opts)
  if not args.query or args.query == "" then
    callback({
      content = { "Error: Please provide a search query" },
      display_content = { "❌ No search query provided" },
      kind = "failed",
    })
    return
  end

  local limit = args.limit or 5
  if limit < 1 then
    limit = 1
  end
  if limit > 100 then
    limit = 100
  end
  local offset = args.offset or 0
  local url = "https://api.core.ac.uk/v3/search/works"
  local payload = {
    q = args.query,
    limit = limit,
    offset = offset + 2, -- Skip first 2 "recommended" papers to get actual search results
    stats = false,
  }
  local json_payload = vim.json.encode(payload)

  local curl_args = { "curl", "-X", "POST" }

  table.insert(curl_args, "-H")
  table.insert(curl_args, "Content-Type: application/json")

  local api_key = os.getenv("CORE_API_KEY")
  if api_key then
    table.insert(curl_args, "-H")
    table.insert(curl_args, "Authorization: Bearer " .. api_key)
  end

  table.insert(curl_args, "-d")
  table.insert(curl_args, json_payload)

  table.insert(curl_args, url)

  local search_description = string.format("Search research papers: %s", args.query)
  opts.user_input(search_description, {
    wrap = true,
    on_accept = function()
      vim.system(
        curl_args,
        { text = true },
        vim.schedule_wrap(function(result)
          if result.code ~= 0 then
            local error_msg = result.stderr and result.stderr ~= "" and result.stderr
              or string.format("curl failed with exit code: %d", result.code)
            callback({
              content = {
                string.format("Error: Failed to fetch research papers - %s", error_msg),
              },
              display_content = { FAILED_FETCH },
              kind = "failed",
            })
            return
          end

          local ok, json =
            pcall(vim.json.decode, result.stdout, { luanil = { object = true } })
          if ok then
            if json.message then
              callback({
                content = {
                  "Error: CORE API is currently overloaded. Please try again in a few moments.",
                  "Suggestion: Try a more specific query or reduce the limit parameter.",
                },
                display_content = { "⏳ CORE API overloaded - try again later" },
                kind = "failed",
              })
              return
            end

            local content = {}
            local resultCount = json.results and #json.results or 0

            if json.totalHits then
              table.insert(
                content,
                string.format("# Research Papers for: %s", args.query)
              )
              table.insert(content, "")
              table.insert(
                content,
                string.format(
                  "Found %s total papers, showing top %d:",
                  json.totalHits,
                  math.min(limit, resultCount)
                )
              )
              table.insert(content, "")
            end

            if resultCount > 0 then
              for i, item in ipairs(json.results) do
                local title =
                  string.gsub(item.title or "Untitled", "\n", " "):gsub("%s+", " ")
                table.insert(content, string.format("## Paper %d: %s", i, title))

                if item.id then
                  table.insert(content, string.format("**ID:** %s", item.id))
                end

                local authors = {}
                if item.authors then
                  for _, author in ipairs(item.authors) do
                    local name = string.gsub(author.name or "", "\n", " ")
                    if name ~= "" then
                      table.insert(authors, name)
                    end
                  end
                end
                table.insert(
                  content,
                  string.format(
                    "**Authors:** %s",
                    #authors > 0 and table.concat(authors, ", ") or "Unknown"
                  )
                )

                table.insert(
                  content,
                  string.format("**Year:** %s", item.yearPublished or "Unknown")
                )

                if item.doi then
                  table.insert(content, string.format("**DOI:** %s", item.doi))
                end
                if item.arxivId then
                  table.insert(content, string.format("**arXiv:** %s", item.arxivId))
                end

                if item.abstract then
                  table.insert(content, "**Abstract:**")
                  local abstract =
                    string.gsub(item.abstract, "\n", " "):gsub("%s+", " ")
                  table.insert(content, abstract)
                end
                table.insert(content, "")
              end
            else
              table.insert(content, "No research papers found for this query.")
              table.insert(content, "Try:")
              table.insert(content, "- Using different keywords")
              table.insert(content, "- Broadening your search terms")
              table.insert(content, "- Adjusting the year range")
            end

            local display_content =
              string.format("📚 Found %d research papers", resultCount)
            callback({
              content = content,
              display_content = { display_content },
            })
          else
            callback({
              content = { "Error: Failed to parse response from CORE API" },
              display_content = { FAILED_FETCH },
              kind = "failed",
            })
          end
        end)
      )
    end,
  })
end)
