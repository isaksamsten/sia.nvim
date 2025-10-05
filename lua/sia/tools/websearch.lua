local tool_utils = require("sia.tools.utils")
local FAILED_FETCH = "❌ Failed to fetch search results"
local FAILED_TO_ACCESS = "❌ Failed to access search"

return tool_utils.new_tool({
  name = "websearch",
  is_available = function()
    return os.getenv("GOOGLE_SEARCH_API_KEY") ~= nil
      and os.getenv("GOOGLE_SEARCH_CX") ~= nil
  end,
  message = function(args)
    if args.description then
      return string.format("%s...", args.description)
    end
    return string.format("Searching for: %s", args.query)
  end,
  description = "Searches the web using Google",
  system_prompt = [[- Searches the web using Google Custom Search API
- Returns search results with titles, URLs, and snippets
- Use this tool when you need to find current information, documentation, or
  resources online

Usage notes:
  - The top 10 results are shown
  - Use specific, targeted search queries for better results]],
  parameters = {
    query = {
      type = "string",
      description = "The search query",
    },
    description = {
      type = "string",
      description = "Clear, consice description of the search in 3-10 words",
    },
  },
  required = { "query" },
  read_only = true,
}, function(args, _, callback, opts)
  if not vim.fn.executable("curl") then
    callback({
      content = { "Error: curl is not installed. Don't try again." },
      display_content = { FAILED_TO_ACCESS },
    })
    return
  end
  if not os.getenv("GOOGLE_SEARCH_API_KEY") then
    callback({
      content = {
        "Error: The GOOGLE_SEARCH_API_KEY API key has not been set by the user.",
      },
      display_content = { FAILED_TO_ACCESS },
    })
    return
  end
  if not os.getenv("GOOGLE_SEARCH_CX") then
    callback({
      content = {
        "Error: The GOOGLE_SEARCH_CX programmable search id has not been set by the user.",
      },
      display_content = { FAILED_TO_ACCESS },
    })
    return
  end

  local curl_args = {
    "curl",
    "-G",
    "https://www.googleapis.com/customsearch/v1",
    "--data-urlencode",
    "key=" .. os.getenv("GOOGLE_SEARCH_API_KEY"),
    "--data-urlencode",
    "cx=" .. os.getenv("GOOGLE_SEARCH_CX"),
    "--data-urlencode",
    "q=" .. args.query,
  }

  opts.user_input(string.format("Search for: %s", args.query), {
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
                string.format("Error: Failed to fetch search results - %s", error_msg),
              },
              display_content = { FAILED_FETCH },
            })
            return
          end

          local ok, json = pcall(vim.json.decode, result.stdout)
          if ok then
            local content = {}
            local searchCount = json.items and #json.items or 0

            if json.searchInformation then
              table.insert(
                content,
                string.format("# Search Results for: %s", args.query)
              )
              table.insert(content, "")
              table.insert(
                content,
                string.format(
                  "Found %s total results, showing top %d:",
                  json.searchInformation.totalResults,
                  searchCount
                )
              )
              table.insert(content, "")
            end

            if searchCount > 0 then
              for i, item in ipairs(json.items or {}) do
                table.insert(content, string.format("## Result %d", i))
                table.insert(content, string.format("**Title:** %s", item.title))
                table.insert(content, string.format("**URL:** %s", item.link))
                table.insert(
                  content,
                  string.format("**Description:** %s", item.snippet)
                )
                table.insert(content, "")
              end
            else
              table.insert(content, "No search results found for this query.")
            end

            local display_content = args.description
                and string.format("🔍 %s", args.description)
              or string.format("🔍 Search results for: %s", args.query)
            callback({
              content = content,
              display_content = { display_content },
            })
          else
            callback({
              content = { "Error: Failed to parse json response from search" },
              display_content = { FAILED_FETCH },
            })
          end
        end)
      )
    end,
  })
end)
