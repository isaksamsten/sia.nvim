local tool_utils = require("sia.tools.utils")
local icons = require("sia.ui").icons
local tool_names = tool_utils.tool_names


--- Get the directory containing the fetch-page script (relative to plugin root).
--- @return string
local function get_script_dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  local plugin_root = vim.fn.fnamemodify(source, ":h:h:h:h")
  return vim.fs.joinpath(plugin_root, "scripts", "fetch-page")
end

--- Install dependencies for the fetch-page script if needed.
--- @param script_dir string
--- @param callback fun(ok: boolean, err: string?)
local function ensure_deps(script_dir, callback)
  local node_modules = vim.fs.joinpath(script_dir, "node_modules")
  if vim.fn.isdirectory(node_modules) == 1 then
    callback(true)
    return
  end

  vim.system(
    { "npm", "install", "--prefix", script_dir },
    { text = true },
    vim.schedule_wrap(function(result)
      if result.code ~= 0 then
        local msg = (result.stderr and result.stderr ~= "") and result.stderr
          or string.format("npm install failed (exit %d)", result.code)
        callback(false, msg)
      else
        callback(true)
      end
    end)
  )
end

return tool_utils.new_tool({
  name = "webfetch",
  message = function(args)
    return string.format("Fetching %s...", args.url)
  end,
  description = "Fetch a URL, convert to clean markdown, download images and take a screenshot",
  is_available = function()
    return vim.fn.executable("npm") == 1 and vim.fn.executable("node") == 1
  end,
  system_prompt = string.format([[- Fetches content from a specified URL using a headless browser
- Cleans HTML with Mozilla Readability and converts to markdown
- Downloads page images locally and takes a full-page screenshot
- Returns the page content along with file paths to the output directory
- Use this tool when you need to retrieve and analyze web content

Usage notes:
  - The URL must be a fully-formed valid URL (http:// or https://)
  - This tool is read-only and does not modify any project files
  - When content is large, the result is truncated. Use the `%s` tool on the
    provided index.md path to view the full content.
  - A screenshot is always saved. Use the `%s` tool on the provided
    screenshot.png path to view it when visual context would be helpful.
  - Downloaded images are stored in the images/ subdirectory of the output.]], tool_names.view, tool_names.view_image),
  parameters = {
    url = {
      type = "string",
      description = "The URL to fetch and convert to markdown",
    },
    timeout = {
      type = "number",
      description = "Timeout in seconds (default: 30, max: 120)",
    },
  },
  required = { "url" },
  read_only = true,
}, function(args, conversation, callback, opts)
  if not args.url or args.url:match("^%s*$") then
    callback({
      content = { "Error: No URL specified" },
      display_content = icons.error .. " Failed to fetch URL",
    })
    return
  end

  if not args.url:match("^https?://") then
    callback({
      content = { "Error: URL must start with http:// or https://" },
      display_content = icons.error .. " Invalid URL format",
    })
    return
  end

  local timeout = math.max(1, math.min(args.timeout or 30, 120))

  opts.user_input(string.format("Fetch URL: %s", args.url), {
    on_accept = function()
      local script_dir = get_script_dir()
      local script = vim.fs.joinpath(script_dir, "index.mjs")

      if vim.fn.filereadable(script) ~= 1 then
        callback({
          content = { "Error: fetch-page script not found at " .. script },
          display_content = icons.error .. " fetch-page script missing",
        })
        return
      end

      ensure_deps(script_dir, function(ok, err)
        if not ok then
          callback({
            content = {
              "Error installing fetch-page dependencies: " .. (err or "unknown"),
            },
            display_content = icons.error .. " npm install failed",
          })
          return
        end

        local fetch_dir = tool_utils.get_fetch_output_dir(conversation.id)
        local fetch_id = tostring(vim.uv.hrtime())
        local output_dir = vim.fs.joinpath(fetch_dir, fetch_id)
        vim.fn.mkdir(output_dir, "p")

        vim.system(
          { "node", script, args.url, output_dir },
          { text = true, timeout = (timeout + 10) * 1000 },
          vim.schedule_wrap(function(result)
            if result.code ~= 0 then
              local error_msg = (result.stderr and result.stderr ~= "")
                  and result.stderr
                or string.format("fetch-page failed (exit %d)", result.code)
              callback({
                content = { "Error: " .. error_msg },
                display_content = icons.error .. " Failed to fetch URL",
              })
              return
            end

            local index_path = vim.fs.joinpath(output_dir, "index.md")
            local screenshot_path = vim.fs.joinpath(output_dir, "screenshot.png")
            local images_dir = vim.fs.joinpath(output_dir, "images")

            local f = io.open(index_path, "r")
            if not f then
              callback({
                content = { "Error: fetch-page produced no output" },
                display_content = icons.error .. " Failed to fetch URL",
              })
              return
            end
            local markdown = f:read("*a")
            f:close()

            local image_count = 0
            local images_handle = vim.uv.fs_scandir(images_dir)
            if images_handle then
              while vim.uv.fs_scandir_next(images_handle) do
                image_count = image_count + 1
              end
            end

            local content = {}
            local max_inline = 8000

            table.insert(content, string.format("Fetched: %s", args.url))
            table.insert(content, "")
            table.insert(content, "Output files:")
            table.insert(content, string.format("  - Markdown: %s", index_path))
            table.insert(content, string.format("  - Screenshot: %s", screenshot_path))
            if image_count > 0 then
              table.insert(
                content,
                string.format("  - Images: %s (%d files)", images_dir, image_count)
              )
            end
            table.insert(content, "")

            if #markdown > max_inline then
              table.insert(
                content,
                string.format(
                  "Content: (truncated, %d chars total - use `%s` tool on %s for full content)",
                  #markdown,
                  tool_names.view,
                  index_path
                )
              )
              table.insert(content, "")
              for _, line in ipairs(vim.split(markdown:sub(1, max_inline), "\n")) do
                table.insert(content, line)
              end
              table.insert(content, "")
              table.insert(content, "... (truncated)")
            else
              table.insert(content, "Content:")
              table.insert(content, "")
              for _, line in ipairs(vim.split(markdown, "\n", { trimempty = true })) do
                table.insert(content, line)
              end
            end

            callback({
              content = content,
              display_content = string.format("%s Fetched %s", icons.fetch, args.url),
            })
          end)
        )
      end)
    end,
  })
end)
