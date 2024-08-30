# Sia

![](assets/logo.png)

An LLM assistant for Neovim with support for

- [Neovim builtin diff tool](https://neovim.io/doc/user/diff.html).
- Simple chat
- Simple insert

## 💡 Idea

The idea behind this plugin, Sia, is to enhance the writing and editing process
within Neovim by integrating a powerful language model (LLM) to assist users in
refining their text. It aims to provide a seamless way to interact with AI for
tasks such as correcting grammar, improving clarity, and ensuring adherence to
academic standards, particularly for scientific manuscripts written in LaTeX.
By leveraging Neovim's built-in diff capabilities, Sia allows users to see the
differences between their original text and the AI-generated suggestions,
making it easier to understand and implement improvements. This combination of
AI assistance and efficient text editing tools empowers users to produce
high-quality written content more effectively.

## ✨ Features

- Prompt selected line into LLM and highlight the differences with the original text.
- Complete code, sentence
- Chat with an LLM

## ⚡️ Requirements

- Neovim >= **0.9**
- curl
- Access to OpenAI API

## 📦 Installation

1. Install using a plugin manager

```lua
-- using lazy.nvim
{
  "isaksamsten/sia.nvim",
  opts = {},
  -- Not required but it improve upon built-in diff view with char diff
  dependencies = {
    {
      "rickhowe/diffchar.vim",
      keys = {
        { "[z", "<Plug>JumpDiffCharPrevStart", desc = "Previous diff", silent = true },
        { "]z", "<Plug>JumpDiffCharNextStart", desc = "Next diff", silent = true },
        { "do", "<Plug>GetDiffCharPair", desc = "Obtain diff", silent = true },
        { "dp", "<Plug>PutDiffCharPair", desc = "Put diff", silent = true },
      },
    },
  },
}
```

2. [get an OpenAI API key](https://platform.openai.com/docs/api-reference/introduction) and add it to your environment as `OPENAI_API_KEY`.

## 🚀 Usage

**Normal Mode**

- `:Sia [query]` send current context and query and insert the response into the buffer.
- `:Sia [query]` if `ft=sia` send the full buffer and the query and insert the
  response in the chat
- `:Sia /prompt [query]` send current context and use the stored `/prompt`
  and insert the response in the buffer.

**Ranges**

- `:'<,'>Sia [query]` send the selected lines and query and diff the response
- `:'<,'>Sia /prompt [query]` send the selected lines and the stored prompt
- `:%Sia /prompt` send the buffer and the query

![](assets/demo.mov)

Read the Neovim [documentation](https://neovim.io/doc/user/diff.html) to learn how to navigate between and edit differences.

## 🙏 Acknowledgments

This plugin is based on a fork of

- [S1M0N38/dante.nvim](https://github.com/S1M0N38/dante.nvim)
