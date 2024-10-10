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

--- Find the span of lines in needle in haystack.
---  - if ignore_whitespace, then empty lines are ignored and two spans with
---    the same content but differences in whitespace is considered similar
---  - if threshold is a number (between 0 and 1), fuzzy match lines.
---
---  TODO: consider finding all matching spans and score them to so we can
---  select the best and not only the first
---
--- @param needle string[]
--- @param haystack string[]
--- @param opts {threshold: number?, ignore_whitespace: boolean?}?
--- @return [integer, integer]? position the position in haystack of the first match.
function M.find_subsequence_span(needle, haystack, opts)
  local function is_empty(line)
    return line:match("^%s*$") ~= nil -- Treat lines with only whitespace as empty
  end

  opts = opts or {}
  local threshold = opts.threshold
  local ignore_whitespace = opts.ignore_whitespace or false

  local needle_len = #needle
  local haystack_len = #haystack

  -- Iterate through y to find a potential starting point
  for i = 1, haystack_len do
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
  end

  return nil
end

return M
