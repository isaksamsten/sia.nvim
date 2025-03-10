local M = {}

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

  return match_end_a - longest_match_len + 1, match_end_b - longest_match_len + 1, longest_match_len
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

local function gen_in_conflict()
  local IN_SEARCH = 0
  local IN_OURS = 1
  local IN_THEIRS = 2
  local conflict_start = "^<<<<<<?<?<?<?"
  local conflict_end = "^>>>>>>?>?>?>?>"
  local conflict_delimiter = "^======?=?=?=?"

  local current_conflict_state = IN_SEARCH
  return function(line)
    if current_conflict_state == IN_OURS then
      if line:match(conflict_delimiter) then
        current_conflict_state = IN_THEIRS
      end
      return true
    elseif current_conflict_state == IN_THEIRS then
      if line:match(conflict_end) then
        current_conflict_state = IN_SEARCH
      end
      return true
    else
      if line:match(conflict_start) then
        current_conflict_state = IN_OURS
        return true
      end
      return false
    end
  end
end
--- Find the span of lines in needle in haystack.
---  - if ignore_whitespace, then empty lines are ignored and two spans with
---    the same content but differences in whitespace is considered similar
---  - if threshold is a number (between 0 and 1), fuzzy match lines.
---
--- @param needle string[]
--- @param haystack string[]
--- @param opts {threshold: number?, ignore_whitespace: boolean?, ignore_conflicts: boolean?}?
--- @return [integer, integer]? position the position in haystack of the first match.
function M.find_subsequence_span(needle, haystack, opts)
  local function is_empty(line)
    return line:match("^%s*$") ~= nil -- Treat lines with only whitespace as empty
  end

  opts = opts or {}
  local threshold = opts.threshold
  local ignore_whitespace = opts.ignore_whitespace or false
  local in_conflict = nil
  if opts.ignore_conflicts or true then
    in_conflict = gen_in_conflict()
  end

  local needle_len = #needle
  local haystack_len = #haystack

  -- Iterate through y to find a potential starting point
  for i = 1, haystack_len do
    -- Skip the starting position if it's in a conflict region
    if in_conflict and in_conflict(haystack[i]) then
      goto outer_continue
    end

    local haystack_idx = i
    local needle_idx = 1
    local start_pos = -1

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

      if needle[needle_idx] == haystack[haystack_idx] then
        needle_idx = needle_idx + 1
        haystack_idx = haystack_idx + 1
        goto continue
      end

      if threshold then
        local dist = M.similarity_ratio(needle[needle_idx], haystack[haystack_idx])
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

--- Find the top-k spans of lines in needle that match in haystack with similarity scoring.
---  - if ignore_whitespace, then empty lines are ignored and two spans with
---    the same content but differences in whitespace is considered similar
---  - scores all potential spans regardless of threshold and returns the top-k highest scoring spans
---  - it uses some tricks but is still rather slow.
---
--- @param needle string[]
--- @param haystack string[]
--- @param opts {ignore_whitespace: boolean?, threshold: number?, limit: integer?, ignore_conflicts: boolean?}?
--- @return {span: [integer, integer], score: number}[]
function M.find_best_subsequence_span(needle, haystack, opts)
  local function is_empty(line)
    return line:match("^%s*$") ~= nil
  end

  opts = opts or {}
  local ignore_whitespace = opts.ignore_whitespace or false
  local limit = opts.limit or 1
  local threshold = opts.threshold or 0
  local in_conflict = nil
  if opts.ignore_conflicts ~= false then
    in_conflict = gen_in_conflict()
  end

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
    if in_conflict and in_conflict(haystack[i]) then
      goto next_start_position
    end

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
      if needle[needle_idx] == haystack[haystack_idx] then
        similarity = 1.0
      else
        similarity = M.similarity_ratio(needle[needle_idx], haystack[haystack_idx])
      end

      sum_similarity = sum_similarity + similarity
      matched_lines = matched_lines + 1

      -- Early pruning: if we can't reach the threshold or the current min score in top matches, abort this match
      if matched_lines > 0 then
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

      if avg_score >= threshold then
        local match = {
          span = { start_pos, haystack_idx - 1 },
          score = avg_score,
        }

        if avg_score == 1.0 then
          return { match }
        end

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

return M
