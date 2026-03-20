# Tool Confirmation

Sia includes a confirmation system that lets you control how tool operations
are approved. You can choose between blocking (traditional) and non-blocking
(async) modes.

## Blocking Mode (Default)

With the default settings, tool operations show an approval prompt immediately
and wait for your response before continuing. This is simple and predictable,
but interrupts your editing flow for each tool call.

## Async Mode

https://github.com/user-attachments/assets/7d9607c9-0846-4415-b32a-db1b51abbf56

When enabled, confirmation requests are queued in the background. You continue
working and batch-process approvals when ready.

Enable it in your config:

```lua
require("sia").setup({
  settings = {
    ui = {
      confirm = {
        async = {
          enable = true,
        },
      },
    },
  },
})
```

### How It Works

1. When a tool needs confirmation, a notification appears in a floating window:

   ```
   [conversation-name] Execute bash command 'git status'
   ```

   Related requests are grouped by conversation and tool name, so parallel
   calls collapse into a single summary.

2. When you are ready, process confirmations using these functions:

   | Function                           | Description                         |
   | ---------------------------------- | ----------------------------------- |
   | `require("sia").confirm.prompt()`  | Show the full confirm prompt        |
   | `require("sia").confirm.accept()`  | Auto-accept without prompt          |
   | `require("sia").confirm.always()`  | Persist an allow rule, then execute |
   | `require("sia").confirm.decline()` | Auto-decline without prompt         |
   | `require("sia").confirm.preview()` | Preview without executing           |
   | `require("sia").confirm.expand()`  | Open detailed grouped view          |

   `accept()` and `decline()` operate on whole groups when possible.
   `prompt()` and `preview()` drill into individual requests.

### Expanded View

The expanded view shows a focusable strip with conversation headers,
tool groups, and selected-item details.

| Key       | Action                                       |
| --------- | -------------------------------------------- |
| `h` / `l` | Move between groups                          |
| `j` / `k` | Move between items in a group                |
| `a` / `d` | Accept or decline the selected item          |
| `A` / `D` | Accept or decline the whole group            |
| `r` / `R` | Always allow the selected item or group      |
| `p` / `v` | Open prompt or preview for the selected item |
| `g?`      | Show help popup                              |
| `q`       | Close the expanded view                      |

### Notification Highlights

Notifications use highlight groups based on the highest risk level in the group:

- `SiaApproveInfo` — standard risk (default)
- `SiaApproveSafe` — safe/low risk
- `SiaApproveWarn` — warning/high risk

### Built-in Notifiers

- `require("sia.ui.confirm").floating_notifier()` — floating window at top
  of screen (default)

### Custom Notifiers

A notifier must implement the `sia.ConfirmNotifier` interface:

- `show(args)` — show or update the notification. `args` contains:
  - **level** — risk level (`"safe"`, `"info"`, or `"warn"`)
  - **name** — conversation name
  - **message** — notification text
  - **total** — number of pending confirmations
- `clear()` — dismiss the notification

Example using nvim-notify:

```lua
require("sia").setup({
  settings = {
    ui = {
      confirm = {
        async = {
          enable = true,
          notifier = (function()
            local notif_id = nil
            return {
              show = function(args)
                notif_id = vim.notify(args.message, vim.log.levels.INFO, {
                  title = "Sia confirm",
                  timeout = false,
                  replace = notif_id,
                })
              end,
              clear = function()
                if notif_id then
                  vim.notify("", vim.log.levels.INFO, {
                    timeout = 0,
                    replace = notif_id,
                  })
                  notif_id = nil
                end
              end,
            }
          end)(),
        },
      },
    },
  },
})
```
