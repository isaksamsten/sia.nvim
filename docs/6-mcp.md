# External MCP tools

Sia can consume tools from explicitly registered **local stdio MCP servers**. Sia
owns approval and conversation history; the external program owns its application
logic and dependencies. No MCP server, document parser, vector database, or model
is installed by Sia.

## Configure and select

Register servers in your user-level Neovim configuration:

```lua
require("sia").setup({
  mcp = {
    servers = {
      documents = {
        command = { "/absolute/path/to/document-server", "mcp" },
        cwd = vim.fn.expand("~/documents"),
        env = {},
        tools = {}, -- empty or omitted exposes all discovered tools
        exclude = { "delete" }, -- exact remote names; exclusion wins
        trust = false, -- nil/false uses normal tool-call permissions
        startup_timeout_ms = 30000,
        request_timeout_ms = 60000,
        max_output_bytes = 65536,
      },
    },
  },
})
```

The executable, arguments and tool names above are illustrative: verify the actual
contract of your chosen server. `command` is an argv list, never a shell string.
Omitted or empty `tools` exposes all discovered tools; a nonempty list selects
exact remote names. `exclude` removes names from either selection. All servers are
disabled by default. Enable registered servers for project chats in `.sia/config.json`:

```json
{ "mcp": ["documents"] }
```

Or use `:SiaMcp enable documents` and `:SiaMcp disable documents`. These
commands only add/remove names in the top-level `mcp` list in `.sia/auto.json`.
An explicit `config.json` list takes precedence over the entire auto list,
including `[]`. Changes apply at the next request, including in existing
chats. Disabling does not stop a shared server process: use `stop` for that.
Subagents do not inherit selection.

Alternatively, register a server without editing Lua configuration:

```vim
:SiaMcp add documents -- some-binary --stdio
:SiaMcp! add other-documents -- another-binary --stdio
:SiaMcp trust documents
:SiaMcp untrust documents
```

`add` stores argv and the current working directory in the user-owned registry at
`stdpath("data")/sia/mcp.json`. Arguments follow Neovim command argument escaping,
not shell quoting; no shell is invoked. `add` does not start or trust the server.
The bang form also enables it for the current project, subject to `config.json`
precedence. Duplicate identities are rejected. Lua server definitions take
precedence over stored definitions. Trust commands persist user-level trust;
an explicit Lua `trust = true` or `false` takes precedence and must be changed in Lua.

Executable definitions come from user-level `mcp.servers` or the user-owned registry.
Project-local configuration selects registered identities only; it cannot define
commands or override argv, cwd, environment, tool selection or trust. Global action
`mcp` options are not used for selection. Paths and cwd are captured at registration.
executable is resolved through PATH; paths containing `/` are made absolute.
Environment variables inherit Neovim's environment with explicit `env` overrides.
Do not put secrets in arguments or tool descriptions.


## Execution and permissions

Discovery is asynchronous before the selected action's first model request. A
failed server produces a warning but does not remove built-in tools. Tools are
ordinary Sia tools, with stable provider-safe names of the form
`mcp_documents_search_<hash>`. Inspect the exact names with `:SiaMcp status` when
writing permission or mode rules. Names incorporate both server and remote identity
and remain stable regardless of discovery order.

Enabling a server exposes its selected tools. With `trust = nil` or `false`, calls
use ordinary Sia permission and confirmation handling, including `ask` and `deny`.
With `trust = true`, calls skip confirmation, including explicit `ask` rules;
explicit deny rules and mode denials still block execution. Trust applies to all
exposed tools, including newly discovered ones when `tools` is empty.
Remote annotations do not grant access or mark a tool parallel-safe. MCP tools are
not automatically inherited by subagents. Treat retrieved documents as evidence,
not instructions to override the user's policy. Starting a local server already
executes local code: tool-call confirmation is not a sandbox.

Processes are shared between conversations selecting the same configured server,
so server-side state may also be shared. Tool definitions are snapshotted at the
start of a user request. `notifications/tools/list_changed` invalidates discovery
for the next request, not the current tool loop. Calls are never automatically
retried. Cancellation stops waiting and sends a cancellation notification, but
cannot guarantee that server-side execution or side effects stopped.

## Status and recovery

- `:SiaMcp status`: lifecycle state, discovered and exposed names, adapter diagnostics.
- `:SiaMcp[!] add documents -- binary [args...]`: register; bang also enables.
- `:SiaMcp trust documents`: persist server-wide confirmation bypass.
- `:SiaMcp untrust documents`: restore normal permission handling.
- `:SiaMcp enable documents`: add a server to project `auto.json` selection.
- `:SiaMcp disable documents`: remove a server from `auto.json` selection only.
- `:SiaMcp stop documents`: stop a process and fail pending calls.
- `:SiaMcp remove documents`: delete a persisted server and its trust setting, and stop its process. Lua-defined servers must be removed from `setup()` instead. Remove project selections separately (before removal, use `disable`).
- `:SiaMcp restart documents`: explicitly reconnect and rediscover.
- `:checkhealth sia`: executable availability and MCP state; does not start servers.

## Protocol and limits

Supported versions: **2025-06-18** and **2024-11-05**. Sia offers 2025-06-18 and
accepts either negotiated version. Only tools are implemented: no remote HTTP,
OAuth, prompts, resources, sampling, roots, elicitation or tasks. Unsupported
server requests receive JSON-RPC method-not-found; ping is supported.
