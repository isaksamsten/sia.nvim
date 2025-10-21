local tool_utils = require("sia.tools.utils")

local MAX_FILE_SIZE = 5 * 1024 * 1024
local SUB_AGENT_PROMPT = [[Analyze webpage content and provide:

1. CONCISE SUMMARY: Key information addressing the request (be specific, avoid fluff)
2. RELATED_LINKS: 3-7 most valuable URLs from this page

Link format:
URL: [full_url]
RELEVANCE: [specific value for original question]

Prioritize links that: provide official docs/APIs, fill summary gaps, offer actionable
resources, or connect related concepts.]]

local ALLOWED_CONTENT_TYPES = {
  "text/html",
  "text/plain",
  "text/markdown",
  "text/xml",
  "application/json",
  "application/xml",
  "application/rss+xml",
  "application/atom+xml",
  "text/csv",
  "application/javascript",
  "application/xhtml+xml",
}

--- @param html_content string
--- @param callback fun(md: string?):nil
local function html_to_markdown(html_content, callback)
  local temp_html = vim.fn.tempname() .. ".html"

  local html_file = io.open(temp_html, "w")
  if not html_file then
    callback(nil)
    return
  end
  html_file:write(html_content)
  html_file:close()

  if vim.fn.executable("pandoc") then
    local pandoc_args = {
      "pandoc",
      temp_html,
      "-t",
      "gfm-raw_html",
      "--wrap=none",
    }

    vim.system(
      pandoc_args,
      { text = true },
      vim.schedule_wrap(function(result)
        vim.fn.delete(temp_html)
        if
          result.stdout
          and result.stdout ~= ""
          and not result.stdout:match("^%s*$")
        then
          callback(result.stdout)
        else
          callback(nil)
        end
      end)
    )
  else
    callback(nil)
  end
end

return tool_utils.new_tool({
  name = "fetch",
  message = function(args)
    return string.format("Fetching %s...", args.url)
  end,
  description = "Fetch URL and convert to markdown with caching",
  system_prompt = [[- Fetches content from a specified URL
- Takes a URL and a prompt as input
- Fetches the URL content, converts HTML to markdown
- Returns the model's response about the content
- Use this tool when you need to retrieve and analyze web content

Usage notes:
  - IMPORTANT: if another tool is present that offers better web fetching
    capabilities, is more targeted to the task, or has fewer restrictions, prefer
    using that tool instead of this one.
  - The URL must be a fully-formed valid URL
  - The prompt should describe what information you want to extract from the page
  - This tool is read-only and does not modify any files
  - Results may be summarized if the content is very large]],
  parameters = {
    url = {
      type = "string",
      description = "The URL to fetch and convert to markdown",
    },
    prompt = {
      type = "string",
      description = "Prompt with information on what to extract from the page.",
    },
    timeout = {
      type = "number",
      description = "Timeout in seconds (default: 30, max: 120)",
    },
  },
  required = { "url" },
  read_only = true,
}, function(args, _, callback, opts)
  if not (vim.fn.executable("curl") or vim.fn.executable("pandoc")) then
    callback({
      content = { "Error: curl and pandoc are not installed. Don't try again." },
      display_content = { "❌ Failed to fetch URL" },
    })
  end

  if not args.url or args.url:match("^%s*$") then
    callback({
      content = { "Error: No URL specified" },
      display_content = { "❌ Failed to fetch URL" },
    })
    return
  end

  if not args.url:match("^https?://") then
    callback({
      content = { "Error: URL must start with http:// or https://" },
      display_content = { "❌ Invalid URL format" },
    })
    return
  end

  local timeout = args.timeout or 30
  if timeout > 120 then
    timeout = 120
  elseif timeout < 1 then
    timeout = 1
  end

  local curl_args = {
    "curl",
    "-s",
    "-L",
    "-i",
    "-A",
    "Mozilla/5.0 (compatible; SiaBot/1.0)",
    "--max-time",
    tostring(timeout),
    "--max-filesize",
    tostring(MAX_FILE_SIZE),
    args.url,
  }

  opts.user_input(string.format("Fetch URL: %s", args.url), {
    on_accept = function()
      vim.system(
        curl_args,
        { text = true },
        vim.schedule_wrap(function(result)
          if result.code ~= 0 then
            local error_msg = result.stderr and result.stderr ~= "" and result.stderr
              or string.format("curl failed with exit code: %d", result.code)
            callback({
              content = { string.format("Error: Failed to fetch URL - %s", error_msg) },
              display_content = { "❌ Failed to fetch URL" },
            })
            return
          end

          local raw_content = result.stdout
          if not raw_content or raw_content:match("^%s*$") then
            callback({
              content = { "Error: No content received from URL" },
              display_content = { "❌ No content received" },
            })
            return
          end

          local headers, body = raw_content:match("^(.-\r?\n\r?\n)(.*)$")
          if not headers then
            headers = ""
            body = raw_content
          end

          local content_type = headers:match("[Cc]ontent%-[Tt]ype:%s*([^%s;%r%n]+)")

          if content_type then
            if not content_type then
              callback({
                content = {
                  "Error: Could not determine content type. Only text-based content is supported.",
                },
                display_content = { "❌ Unknown content type" },
              })
              return
            end
            content_type = content_type:lower()

            local is_text_based = false
            for _, allowed in ipairs(ALLOWED_CONTENT_TYPES) do
              if
                content_type == allowed
                or content_type:find(
                  "^" .. allowed:gsub("([%.%+%-%*%?%[%]%^%$%(%)%%])", "%%%1")
                )
              then
                is_text_based = true
                break
              end
            end

            if not is_text_based then
              callback({
                content = {
                  string.format(
                    "Error: Content type '%s' is not text-based. Only text content (HTML, JSON, XML, plain text) is supported.",
                    content_type
                  ),
                },
                display_content = { "❌ Binary content not supported" },
              })
              return
            end
          end

          local Message = require("sia.conversation").Message
          html_to_markdown(body, function(markdown_content)
            local final_content = markdown_content or body
            if args.prompt then
              local config = require("sia.config")
              require("sia.assistant").execute_query({
                Message:from_table({ role = "system", content = SUB_AGENT_PROMPT }),
                Message:from_table({
                  role = "user",
                  content = string.format(
                    "%s. Here's the webpage:\n%s",
                    args.prompt,
                    final_content
                  ),
                }),
              }, {
                model = config.get_default_model("fast_model"),
                callback = function(response)
                  callback({
                    content = vim.split(response, "\n", { trimempty = true }),
                    display_content = { string.format("📄 Fetched %s", args.url) },
                  })
                end,
              })
            else
              callback({
                content = vim.split(final_content, "\n", { trimempty = true }),
                display_content = { string.format("📄 Fetched %s", args.url) },
              })
            end
          end)
        end)
      )
    end,
  })
end)
