local M = {}

local defaults = {
	warn_on_visual = true, -- warn if visual and not visual line mode
	default = {
		model = "gpt-4o-mini", -- default model
		temperature = 0.5, -- default temperature
		prefix = 1, -- prefix lines in insert
		suffix = 0, -- suffix lines in insert
		mode = "auto", -- auto|diff|insert|split
		mode_prompt = {
			chat = {
				{ role = "system", content = "You are an helpful assistant." },
				{ role = "system", content = "This is the ongoing conversation: \n{{buffer}}" },
			},
			insert = {
				{ role = "system", content = "You are an helpful assistant" },
				{ role = "system", content = "This is the current context: \n\n{{context}}" },
				{
					role = "system",
					content = [[Note that the user query is initiated from
  a text editor and that your changes will be inserted verbatim into the editor.
  The editor identifies the file as written in {{filetype}}.

  If possible, make sure that you only output the relevant and requested
  information. Refrain from explaining your reasoning, unless the user requests
  it, or adding unrelated text to the output. If the context pertains to code,
  identify the programming language and do not add any additional text or
  markdown formatting. If explanations are needed add them as relevant comments
  using correct syntax for the identified language.]],
				},
			},
			diff = {
				{ role = "system", content = "You are an helpful assistant" },
				{ role = "system", content = "This is the current context: \n\n{{context}}" },
				{
					role = "system",
					content = [[Note that the user query is initiated from a
  text editor and your changes will be diffed against an optional context
  provided by the user. The editor identifies the file as written in
  {{filetype}}.

  If possible, make sure that you only output the relevant and requested changes.
  Refrain from explaining your reasoning or adding additional unrelated text
  to the output. If the context pertains to code, identify the the programming
  language and DO NOT ADD ANY ADDITIONAL TEXT OR MARKDOWN FORMATTING!]],
				},
			},
		},
	},
	prompts = {
		buffer = {
			prompt = {
				{
					role = "system",
					content = [[Respond to the user query directly in the appropriate
format for {{filetype}}, ensuring your response is concise and
directly relevant. For code files, provide code directly without
additional comments or explanations unless requested. NEVER OUTPUT MARKDOWN
CODEBLOCKS! Focus on providing the exact response needed
for insertion into the text editor.]],
				},
				{
					role = "system",
					content = [[Here is the full text of the buffer:
```{{filetype}}
{{buffer}}
```]],
				},
				{ role = "system", content = "Here is the current context: {{context}}" },
			},
			require_input = true,
			mode = "auto",
		},
		commit = {
			prompt = {
				{
					role = "system",
					content = [[You are an AI assistant tasked with generating concise,
informative, and context-aware git commit messages based on code
diffs. Your goal is to provide commit messages that clearly describe
the purpose and impact of the changes. Consider the following when
crafting the commit message:

1. **Summarize the change**: Clearly describe what was changed, added, removed,
   or fixed.
2. **Explain why**: If relevant, include the reason or motivation behind the
   change.
3. **Keep it concise**: The commit message should be brief but informative,
   typically under 50 characters for the subject line.
4. **Use an imperative tone**: Write the commit message as a command, e.g.,
   "Fix typo in README," "Add unit tests for validation logic." ]],
				},
				{
					role = "user",
					content = function()
						return "Given the git diff listed below, please generate a commit message for me:"
							.. "\n\n```diff\n"
							.. vim.fn.system("git diff --staged")
							.. "\n```"
					end,
				},
			},
			allow_input = false,
			mode = "insert",
			enabled = function()
				local function is_git_repo()
					local handle = io.popen("git rev-parse --is-inside-work-tree 2>/dev/null")
					if handle == nil then
						return false
					end
					local result = handle:read("*a")
					handle:close()
					return result:match("true") ~= nil
				end
				return is_git_repo()
			end,
		},
		explain = {
			prompt = {
				{
					role = "system",
					content = [[When asked to explain code, follow these steps:

1. Identify the programming language.
2. Describe the purpose of the code and reference core concepts from the programming language.
3. Explain each function or significant block of code, including parameters and return values.
4. Highlight any specific functions or methods used and their roles.
5. Provide context on how the code fits into a larger application if applicable.]],
				},
				{
					role = "user",
					content = [[Explain the following code:
```{{filetype}}
{{context}}
```
]],
				},
			},
			mode = "split",
			split_cmd = "vsplit",
			wo = { wrap = true },
			model = "gpt-4o",
			temperature = 0.5,
			visual = true,
		},
	},
	openai_api_key = "OPENAI_API_KEY",
	wo = { "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak" },
	report_usage = true,
}

M.options = {}

function M.setup(options)
	M.options = vim.tbl_deep_extend("force", {}, defaults, options or {})
	if M.options.report_usage == true then
		vim.api.nvim_create_autocmd("User", {
			pattern = "SiaUsageReport",
			callback = function(args)
				local data = args.data
				if data then
					vim.notify("Total tokens: " .. data.total_tokens)
				end
			end,
		})
	end
end

function M._is_disabled(prompt)
	if prompt.enabled ~= nil and (prompt.enabled == false or (type(prompt.enabled) and not prompt.enabled())) then
		return true
	else
		return false
	end
end

return M
