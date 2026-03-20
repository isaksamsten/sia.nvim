# Models and Providers

Sia supports multiple LLM providers. Each model is identified by a
`provider/model-name` string (e.g., `openai/gpt-4.1`, `copilot/claude-sonnet-4.6`).

## Defining Custom Models

You can register custom models in `setup()` with pricing and context window
information:

```lua
require("sia").setup({
  models = {
    ["openrouter/custom-model"] = {
      "openrouter",                                        -- Provider name
      "provider/model-name",                               -- API model identifier
      pricing = { input = 3.00, output = 15.00 },          -- Per 1M tokens in USD
      cache_multiplier = { read = 0.1, write = 1.25 },     -- Optional cache pricing
      context_window = 128000,                              -- Context window in tokens
    },
  },
})
```

All built-in models include `context_window` and `pricing` values. If you
define custom models, set `context_window` so that Sia can track context usage
and manage conversation length automatically. Without it, context tracking and
automatic pruning are disabled for that model.

## Cost Tracking

The chat winbar displays real-time token usage and cost. This works
automatically for built-in models. For custom models, add `pricing` to the
model definition.

**Cache pricing multipliers:**

- **read** — multiplier for tokens read from cache
- **write** — multiplier for cache creation tokens (Anthropic only)

Providers with built-in cache support (Anthropic, OpenAI) apply these
multipliers automatically.

## Model Aliases

You can create aliases for models with custom parameters. Define them in
[project configuration](3-project.md) or in the `models` table:

```json
{
  "aliases": {
    "sonnet-thinking": {
      "name": "copilot/claude-sonnet-4.6",
      "options": {
        "max_tokens": 16000,
        "thinking": { "type": "adaptive" },
        "output_config": { "effort": "high" }
      }
    }
  }
}
```

Use an alias with `:Sia -m sonnet-thinking your prompt here`.

## Provider Parameters

Provider-specific parameters are passed through the **options** field. These
are merged directly into the API request body, so any parameter the underlying
API supports can be used.

### OpenAI Completion API

Used by: `openai`

| Parameter            | Type    | Description                                                       |
| -------------------- | ------- | ----------------------------------------------------------------- |
| **temperature**      | number  | Sampling temperature (0–2). Not compatible with reasoning models. |
| **max_tokens**       | integer | Maximum output tokens                                             |
| **top_p**            | number  | Nucleus sampling threshold (0–1)                                  |
| **n**                | integer | Number of completions to generate                                 |
| **reasoning_effort** | string  | For reasoning models (o1, o3): `"low"`, `"medium"`, `"high"`      |

### OpenAI Responses API

Used by: `openai_responses`, `codex`

| Parameter       | Type    | Description                                                       |
| --------------- | ------- | ----------------------------------------------------------------- |
| **temperature** | number  | Sampling temperature (0–2). Not compatible with reasoning models. |
| **max_tokens**  | integer | Maximum output tokens                                             |
| **top_p**       | number  | Nucleus sampling threshold (0–1)                                  |
| **reasoning**   | object  | Reasoning config: `{ effort, summary }`                           |

The **reasoning** object:

| Field       | Type   | Description                   |
| ----------- | ------ | ----------------------------- |
| **effort**  | string | `"low"`, `"medium"`, `"high"` |
| **summary** | string | `"concise"` or `"detailed"`   |

Example for a Codex reasoning model:

```json
{
  "models": {
    "codex/gpt-5.3-codex": {
      "options": {
        "reasoning": { "effort": "medium" }
      }
    }
  }
}
```

### Anthropic API

Used by: `anthropic`, `claude_code`

| Parameter       | Type    | Description                              |
| --------------- | ------- | ---------------------------------------- |
| **temperature** | number  | Sampling temperature (0–1)               |
| **max_tokens**  | integer | Maximum output tokens. Defaults to 4096. |
| **top_p**       | number  | Nucleus sampling threshold (0–1)         |
| **top_k**       | integer | Top-k sampling                           |

**Extended thinking:**

Claude models support extended thinking in two modes:

- **Adaptive** (recommended for Opus 4.6 and Sonnet 4.6) — the model decides
  when and how much to think. Use `effort` to guide thinking depth.
- **Manual** (older models or precise budget control) — you set an explicit
  token budget with `budget_tokens`.

| Parameter    | Type   | Description                                                       |
| ------------ | ------ | ----------------------------------------------------------------- |
| **thinking** | object | `{ type: "adaptive" \| "enabled" \| "disabled", budget_tokens? }` |
| **effort**   | object | `{ effort: "low" \| "medium" \| "high" \| "max" }`                |

When thinking is enabled, **max_tokens** must be set and covers both thinking
and response tokens.

Adaptive thinking with medium effort:

```json
{
  "models": {
    "anthropic/claude-sonnet-4.6": {
      "options": {
        "max_tokens": 16000,
        "thinking": { "type": "adaptive" },
        "output_config": { "effort": "medium" }
      }
    }
  }
}
```

Manual thinking with a fixed budget:

```json
{
  "models": {
    "anthropic/claude-sonnet-4.5": {
      "options": {
        "max_tokens": 16000,
        "thinking": { "type": "enabled", "budget_tokens": 4000 }
      }
    }
  }
}
```

### Copilot

The Copilot provider routes to different API formats depending on the model:

- **GPT-5+ models** use the Responses API format
- **Claude models** use the OpenAI Completion API format
- **Gemini models** use the OpenAI Completion API format

Claude models through Copilot support extended thinking:

| Parameter           | Type    | Description                             |
| ------------------- | ------- | --------------------------------------- |
| **thinking_budget** | integer | Token budget for reasoning (e.g., 4000) |
| **thinking**        | object  | `{ type: "adaptive" }`                  |
| **max_tokens**      | integer | Required when thinking is enabled       |
| **top_p**           | number  | Typically set to 1 with thinking        |
| **output_config**   | object  | `{ effort: "high" }`                    |

Example:

```json
{
  "models": {
    "copilot/claude-sonnet-4.6": {
      "options": {
        "max_tokens": 16000,
        "top_p": 1,
        "thinking_budget": 4000,
        "thinking": { "type": "adaptive" },
        "output_config": { "effort": "high" }
      }
    }
  }
}
```

### OpenRouter

Used by: `openrouter`

Same parameters as the OpenAI Completion API.

### Gemini

Used by: `gemini` (via OpenAI-compatible endpoint)

Same parameters as the OpenAI Completion API.
