local M = {}
--- @alias sia.matcher.Match {span: [integer, integer], col_span: [integer, integer]?, score: number}

--- Find the longest common substring between two strings.
--- @param a string
--- @param b string
--- @return integer start_a
--- @return integer start_b
--- @return integer length
function M.longest_common_substring(a, b)
  local len_a = #a
  local len_b = #b

  local match_table = {}
  for i = 0, len_a do
    match_table[i] = {}
    for j = 0, len_b do
      match_table[i][j] = 0
    end
  end

  local longest_match_len = 0
  local match_end_a = 0
  local match_end_b = 0

  for i = 1, len_a do
    for j = 1, len_b do
      if a:sub(i, i) == b:sub(j, j) then
        match_table[i][j] = match_table[i - 1][j - 1] + 1
        if match_table[i][j] > longest_match_len then
          longest_match_len = match_table[i][j]
          match_end_a = i
          match_end_b = j
        end
      end
    end
  end

  return match_end_a - longest_match_len + 1,
    match_end_b - longest_match_len + 1,
    longest_match_len
end

--- Calculate the similarity ratio between two strings.
--- @param a string
--- @param b string
--- @return number ratio  where 1 is perfect match and 0 no match. Empty strings do not match.
function M.similarity_ratio(a, b)
  local len_a = #a
  local len_b = #b

  if len_a == 0 or len_b == 0 then
    return 0
  end

  local total_length = len_a + len_b
  local total_matching_chars = 0

  local match_a = a
  local match_b = b

  while true do
    local start_a, start_b, match_len = M.longest_common_substring(match_a, match_b)
    if match_len == 0 then
      break
    end

    total_matching_chars = total_matching_chars + match_len
    match_a = match_a:sub(1, start_a - 1) .. match_a:sub(start_a + match_len)
    match_b = match_b:sub(1, start_b - 1) .. match_b:sub(start_b + match_len)
  end

  return (2 * total_matching_chars) / total_length
end

--- Find the span of lines in needle in haystack.
---  - if ignore_whitespace, then empty lines are ignored and two spans with
---    the same content but differences in whitespace is considered similar
---  - if threshold is a number (between 0 and 1), fuzzy match lines.
---
--- @param needle string[]
--- @param haystack string[]
--- @param opts {threshold: number?, ignore_emptylines: boolean?, ignore_indent: boolean?, ignore_conflicts: boolean?}?
--- @return [integer, integer]? position the position in haystack of the first match.
function M.find_subsequence_span(needle, haystack, opts)
  local function is_empty(line)
    return line:match("^%s*$") ~= nil
  end

  opts = opts or {}
  local threshold = opts.threshold
  local ignore_emptylines = opts.ignore_emptylines or false
  local ignore_indent = opts.ignore_indent or false

  local needle_len = #needle
  local haystack_len = #haystack

  -- Iterate through y to find a potential starting point
  for i = 1, haystack_len do
    local haystack_idx = i
    local needle_idx = 1
    local start_pos = -1

    while haystack_idx <= haystack_len and needle_idx <= needle_len do
      if ignore_emptylines then
        local empty_needle = is_empty(needle[needle_idx])
        local empty_haystack = is_empty(haystack[haystack_idx])
        if empty_needle and empty_haystack then
          needle_idx = needle_idx + 1
          haystack_idx = haystack_idx + 1
          goto continue
        elseif empty_needle then
          needle_idx = needle_idx + 1
          goto continue
        elseif empty_haystack then
          haystack_idx = haystack_idx + 1
          goto continue
        end
      end

      if start_pos == -1 then
        start_pos = haystack_idx
      end

      local needle_str = needle[needle_idx]
      local haystack_str = haystack[haystack_idx]

      if ignore_indent then
        needle_str = needle_str:gsub("^%s+", "")
        haystack_str = haystack_str:gsub("^%s+", "")
      end

      if needle_str == haystack_str then
        needle_idx = needle_idx + 1
        haystack_idx = haystack_idx + 1
        goto continue
      end

      if threshold then
        local dist = M.similarity_ratio(needle_str, haystack_str)
        if dist < threshold then
          break
        end
      else
        break
      end

      needle_idx = needle_idx + 1
      haystack_idx = haystack_idx + 1

      ::continue::
    end

    if needle_idx == needle_len + 1 then
      return { start_pos, haystack_idx - 1 }
    end

    ::outer_continue::
  end

  return nil
end

--- @param needle_str string The string to search for
--- @param haystack_lines string[] Array of lines to search in
--- @param opts {threshold: number?, ignore_case: boolean?, limit: integer?}? Options for matching
--- @return {span: [integer, integer], col_span: [integer, integer], score: number}[]
function M.find_inline_matches(needle_str, haystack_lines, opts)
  opts = opts or {}
  local threshold = opts.threshold
  local ignore_case = opts.ignore_case or false
  local limit = opts.limit
  local matches = {}

  local search_needle = ignore_case and needle_str:lower() or needle_str

  for i, line in ipairs(haystack_lines) do
    -- Early exit if we've reached the limit
    if limit and #matches >= limit then
      break
    end

    local search_line = ignore_case and line:lower() or line

    if threshold then
      local best_score = 0
      local best_start = nil
      local best_end = nil

      local needle_len = #needle_str
      local min_len = math.max(1, math.floor(needle_len * threshold))
      local max_len = math.ceil(needle_len / threshold)

      for start_pos = 1, #search_line do
        for len = min_len, math.min(max_len, #search_line - start_pos + 1) do
          local substring = search_line:sub(start_pos, start_pos + len - 1)
          local score = M.similarity_ratio(search_needle, substring)

          if score >= threshold and score > best_score then
            best_score = score
            best_start = start_pos
            best_end = start_pos + len - 1
          end
        end
      end

      if best_start then
        table.insert(matches, {
          span = { i, i },
          col_span = { best_start, best_end },
          score = best_score,
        })
      end
    else
      local start_pos = 1
      while true do
        -- Early exit if we've reached the limit
        if limit and #matches >= limit then
          break
        end

        local start_col = search_line:find(search_needle, start_pos, true)
        if not start_col then
          break
        end

        table.insert(matches, {
          span = { i, i },
          col_span = { start_col, start_col + #needle_str - 1 },
          score = 1.0,
        })

        start_pos = start_col + 1
      end
    end
  end

  table.sort(matches, function(a, b)
    return a.score > b.score
  end)

  return matches
end

--- Find the top-k spans of lines in needle that match in haystack with similarity scoring.
--- Uses a sophisticated scoring algorithm that evaluates all potential matches and returns
--- the highest scoring ones. Includes early pruning optimizations for performance.
---
--- Features:
---  - if ignore_emptylines is true, empty lines are ignored during matching
---  - if ignore_indent is true, leading/trailing whitespace is normalized before comparison
---  - if threshold is set, only matches with average similarity >= threshold are considered
---  - scores all potential spans and returns the top-k highest scoring spans (limit parameter)
---  - uses early pruning to avoid evaluating matches that cannot reach the minimum score
---  - returns immediately on perfect matches (score = 1.0)
---
--- @param needle string[] Array of lines to search for
--- @param haystack string[] Array of lines to search in
--- @param opts {ignore_emptylines: boolean?, ignore_indent: boolean?, threshold: number?, limit: integer?, ignore_conflicts: boolean?}? Matching options
--- @return {span: [integer, integer], score: number}[] Array of matches sorted by score (highest first)
local function _find_best_subsequence_span(needle, haystack, opts)
  local function is_empty(line)
    return line:match("^%s*$") ~= nil
  end

  opts = opts or {}
  local ignore_whitespace = opts.ignore_emptylines or false
  local ignore_indent = opts.ignore_indent or false
  local limit = opts.limit or 1
  local threshold = opts.threshold

  local needle_len = #needle
  local haystack_len = #haystack
  local top_matches = {}
  local min_top_score = 0

  local total_non_empty_needle = needle_len
  if ignore_whitespace then
    total_non_empty_needle = 0
    for j = 1, needle_len do
      if not is_empty(needle[j]) then
        total_non_empty_needle = total_non_empty_needle + 1
      end
    end
  end

  for i = 1, haystack_len do
    local haystack_idx = i
    local needle_idx = 1
    local start_pos = -1
    local sum_similarity = 0
    local matched_lines = 0

    while haystack_idx <= haystack_len and needle_idx <= needle_len do
      if ignore_whitespace then
        local empty_needle = is_empty(needle[needle_idx])
        local empty_haystack = is_empty(haystack[haystack_idx])
        if empty_needle and empty_haystack then
          needle_idx = needle_idx + 1
          haystack_idx = haystack_idx + 1
          goto continue
        elseif empty_needle then
          needle_idx = needle_idx + 1
          goto continue
        elseif empty_haystack then
          haystack_idx = haystack_idx + 1
          goto continue
        end
      end

      if start_pos == -1 then
        start_pos = haystack_idx
      end

      local similarity
      local needle_str = needle[needle_idx]
      local haystack_str = haystack[haystack_idx]

      if ignore_indent then
        needle_str = needle_str:gsub("%s+", "")
        haystack_str = haystack_str:gsub("%s+", "")
      end

      if needle_str == haystack_str then
        similarity = 1.0
      else
        if threshold then
          similarity = M.similarity_ratio(needle_str, haystack_str)
          if similarity < threshold then
            goto next_start_position
          end
        else
          -- No threshold set, only accept exact matches
          goto next_start_position
        end
      end

      sum_similarity = sum_similarity + similarity
      matched_lines = matched_lines + 1

      -- Early pruning: if we can't reach the threshold or the current min score in top matches, abort this match
      if matched_lines > 0 and threshold then
        -- Calculate best possible final average (if all remaining matches are perfect)
        local remaining = total_non_empty_needle - matched_lines
        local best_possible_avg = (sum_similarity + remaining) / total_non_empty_needle

        local effective_threshold = math.max(threshold, min_top_score)
        if best_possible_avg < effective_threshold then
          goto next_start_position
        end
      end

      needle_idx = needle_idx + 1
      haystack_idx = haystack_idx + 1

      ::continue::
    end

    if needle_idx == needle_len + 1 and start_pos ~= -1 and matched_lines > 0 then
      local avg_score = sum_similarity / matched_lines

      if not threshold or avg_score >= threshold then
        local match = {
          span = { start_pos, haystack_idx - 1 },
          score = avg_score,
        }

        table.insert(top_matches, match)

        table.sort(top_matches, function(a, b)
          return a.score > b.score
        end)

        if #top_matches > limit then
          table.remove(top_matches)
          min_top_score = top_matches[#top_matches].score
        end
      end
    end

    ::next_start_position::
  end

  return top_matches
end

--- @param needle string|string[] The text to search for (can contain newlines)
--- @param haystack string[] Array of lines to search in
--- @return sia.matcher.Match[], boolean fuzzy_used
local function _find_best_match(needle, haystack)
  local needle_lines
  if type(needle) == "string" then
    needle_lines = vim.split(needle, "\n")
  else
    needle_lines = needle
  end
  local matches
  local fuzzy = false

  if needle == "" then
    if #haystack == 0 or (#haystack == 1 and haystack[1] == "") then
      return { { span = { 1, -1 }, score = 1.0 } }, false
    else
      return {}, false
    end
  end

  matches = _find_best_subsequence_span(needle_lines, haystack, { limit = 2 })
  if #matches == 0 then
    fuzzy = true
    matches = _find_best_subsequence_span(needle_lines, haystack, {
      ignore_indent = true,
      limit = 2,
    })
    if #matches == 0 then
      matches = _find_best_subsequence_span(needle_lines, haystack, {
        ignore_indent = true,
        threshold = 0.9,
        limit = 2,
      })
    end
  end

  if #matches == 0 and #needle_lines == 1 then
    fuzzy = false
    matches = M.find_inline_matches(needle_lines[1], haystack, { limit = 2 })
    if #matches == 0 then
      fuzzy = true
      matches = M.find_inline_matches(needle_lines[1], haystack, {
        ignore_case = true,
        limit = 2,
      })
    end
  end

  return matches, fuzzy
end

--- @param text string The text that may contain line numbers
--- @return string[] stripped_text Text with line numbers removed
--- @return boolean had_line_numbers Whether line numbers were detected and stripped
function M.strip_line_numbers(text)
  local lines = vim.split(text, "\n")
  local stripped_lines = {}
  local had_line_numbers = false

  for _, line in ipairs(lines) do
    local stripped_line = line

    local after_tab = line:match("^%s*%d+\t(.*)$")
    if after_tab then
      stripped_line = after_tab
      had_line_numbers = true
    else
      local after_pipe = line:match("^%s*%d+%s*|%s*(.*)$")
      if after_pipe then
        stripped_line = after_pipe
        had_line_numbers = true
      else
        local after_spaces = line:match("^%s*%d+%s%s+(.*)$")
        if after_spaces then
          stripped_line = after_spaces
          had_line_numbers = true
        end
      end
    end

    table.insert(stripped_lines, stripped_line)
  end

  return stripped_lines, had_line_numbers
end

--- Find best match with automatic line number stripping fallback
--- @param needle string The text to search for (can contain newlines)
--- @param haystack string[] Array of lines to search in
--- @return {matches: sia.matcher.Match[],  fuzzy: boolean, strip_line_number: boolean}
function M.find_best_match(needle, haystack)
  local matches, fuzzy = _find_best_match(needle, haystack)

  if #matches == 0 then
    local stripped_needle, had_line_numbers = M.strip_line_numbers(needle)
    if had_line_numbers then
      matches, fuzzy = _find_best_match(stripped_needle, haystack)
      return { matches = matches, fuzzy = true, strip_line_number = true }
    end
  end

  return { matches = matches, fuzzy = fuzzy, strip_line_number = false }
end

return M
