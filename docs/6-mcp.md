# External MCP tools

Sia can consume tools from explicitly trusted **local stdio MCP servers**. Sia
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
        tools = { "search", "read" },
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
The nonempty `tools` allowlist contains exact remote names. All servers are disabled
by default. Enable trusted servers for project chats in `.sia/config.json`:

```json
{ "mcp": ["documents"] }
```

Or use `:SiaMcp enable documents` and `:SiaMcp disable documents`. These commands
only add/remove names in the top-level `mcp` list in `.sia/auto.json`. An explicit
`config.json` list takes precedence over the entire auto list, including `[]`.
Disable never edits `config.json`; its notification reports effective enablement.
Changes apply at the next request, including in existing chats. Disabling does not
stop a shared server process; use `stop` for that. Subagents do not inherit selection.

Executable definitions are read only from user-level `mcp.servers`. Project-local
configuration selects trusted identities only; it cannot define commands or
override argv, cwd, environment or tool allowlists. Global action `mcp` options
are not used for selection. Paths and cwd are captured when setup runs. A bare
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

Enabling a server for a project grants access to its globally allowlisted tools.
Calls run without confirmation, including when an `ask` rule is configured.
Explicit deny rules and mode denials still block execution. Remote annotations
do not grant access or mark a tool parallel-safe. MCP tools are not automatically
inherited by subagents. Treat retrieved documents as evidence, not instructions
to override the user's policy.

Processes are shared between conversations selecting the same configured server,
so server-side state may also be shared. Tool definitions are snapshotted at the
start of a user request. `notifications/tools/list_changed` invalidates discovery
for the next request, not the current tool loop. Calls are never automatically
retried. Cancellation stops waiting and sends a cancellation notification, but
cannot guarantee that server-side execution or side effects stopped.

## Status and recovery

- `:SiaMcp status`: lifecycle state, discovered and exposed names, adapter diagnostics.
- `:SiaMcp enable documents`: add a server to project `auto.json` selection.
- `:SiaMcp disable documents`: remove a server from `auto.json` selection only.
- `:SiaMcp stop documents`: stop a process and fail pending calls.
- `:SiaMcp restart documents`: explicitly reconnect and rediscover.
- `:checkhealth sia`: executable availability and MCP state; does not start servers.

## Protocol and limits

Supported versions: **2025-06-18** and **2024-11-05**. Sia offers 2025-06-18 and
accepts either negotiated version. Only tools are implemented: no remote HTTP,
OAuth, prompts, resources, sampling, roots, elicitation or tasks. Unsupported
server requests receive JSON-RPC method-not-found; ping is supported.
