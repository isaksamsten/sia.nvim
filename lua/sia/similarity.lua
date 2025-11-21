local M = {}

--- Calculate dot product and magnitudes of two vectors in a single pass
--- @param a number[]
--- @param b number[]
--- @return number dot_product
--- @return number magnitude_a
--- @return number magnitude_b
local function dot_and_magnitudes(a, b)
  local dot = 0
  local mag_a_sq = 0
  local mag_b_sq = 0

  for i = 1, #a do
    local a_i = a[i]
    local b_i = b[i]
    dot = dot + a_i * b_i
    mag_a_sq = mag_a_sq + a_i * a_i
    mag_b_sq = mag_b_sq + b_i * b_i
  end

  return dot, math.sqrt(mag_a_sq), math.sqrt(mag_b_sq)
end
--- Calculate dot product
--- @param a number[]
--- @param b number[]
--- @return number dot_product
local function dot_product(a, b)
  local dot = 0

  for i = 1, #a do
    local a_i = a[i]
    local b_i = b[i]
    dot = dot + a_i * b_i
  end

  return dot
end

--- Calculate the magnitude (L2 norm) of a vector
--- @param v number[]
--- @return number
local function magnitude(v)
  local sum = 0
  for i = 1, #v do
    sum = sum + v[i] * v[i]
  end
  return math.sqrt(sum)
end

--- Calculate cosine similarity between two vectors
--- Returns a value between -1 (opposite) and 1 (identical), with 0 meaning orthogonal
--- @param a number[]
--- @param b number[]
--- @return number similarity
function M.cosine_similarity(a, b)
  if #a == 0 or #b == 0 or #a ~= #b then
    return 0
  end

  local dot, mag_a, mag_b = dot_and_magnitudes(a, b)

  if mag_a == 0 or mag_b == 0 then
    return 0
  end

  return dot / (mag_a * mag_b)
end

--- Memoization of magnitude lookup
--- @param embeddings number[][]
--- @return fun(idx):number
local function make_get_magnitude(embeddings)
  local mag_cache = {}

  return function(idx)
    if not mag_cache[idx] then
      mag_cache[idx] = magnitude(embeddings[idx])
    end
    return mag_cache[idx]
  end
end

--- @class sia.similarity.Result
--- @field index integer The index in the target list
--- @field score number The similarity score (0-1)

--- Find the most similar embeddings from a list compared to a query embedding.
--- Supports both sync (no callback) and async (with callback) modes.
---
--- @param query number[] The query embedding vector
--- @param targets number[][] List of target embedding vectors to compare against
--- @param opts {top_k: integer?, time_budget_ms: integer?}? Options
--- @param callback fun(results: sia.similarity.Result[])? Callback for async mode
--- @return sia.similarity.Result[]? results Returns nil in async mode
function M.find_similar(query, targets, opts, callback)
  opts = opts or {}
  local top_k = opts.top_k or 10
  local time_budget_ms = opts.time_budget_ms or 50

  if #query == 0 or #targets == 0 then
    local result = {}
    if callback then
      callback(result)
      return nil
    else
      return result
    end
  end

  local get_magnitude = make_get_magnitude(targets)
  local query_mag = magnitude(query)
  if query_mag == 0 then
    local result = {}
    if callback then
      callback(result)
      return nil
    else
      return result
    end
  end

  local function compute_similarity(target_idx)
    local target_mag = get_magnitude(target_idx)
    if target_mag == 0 then
      return 0
    end

    local target = targets[target_idx]
    local dot = dot_product(query, target)
    return dot / (query_mag * target_mag)
  end

  if not callback then
    local results = {}
    for i = 1, #targets do
      local score = compute_similarity(i)
      table.insert(results, { index = i, score = score })
    end

    table.sort(results, function(a, b)
      return a.score > b.score
    end)

    local top_results = {}
    for i = 1, math.min(top_k, #results) do
      table.insert(top_results, results[i])
    end

    return top_results
  end

  local state = {
    i = 1,
    results = {},
  }

  local function process_batch()
    local start_time = vim.loop.hrtime()
    local time_budget_ns = time_budget_ms * 1000000

    local should_yield = function()
      local elapsed_ns = vim.loop.hrtime() - start_time
      return elapsed_ns >= time_budget_ns
    end

    while state.i <= #targets do
      local score = compute_similarity(state.i)
      table.insert(state.results, { index = state.i, score = score })

      state.i = state.i + 1

      if should_yield() then
        break
      end
    end

    if state.i > #targets then
      table.sort(state.results, function(a, b)
        return a.score > b.score
      end)

      local top_results = {}
      for i = 1, math.min(top_k, #state.results) do
        table.insert(top_results, state.results[i])
      end

      callback(top_results)
    else
      vim.schedule(process_batch)
    end
  end

  process_batch()
  return nil
end

--- Compare all pairs of embeddings and return a similarity matrix.
--- Supports both sync and async modes.
---
--- @param embeddings number[][] List of embedding vectors
--- @param opts {time_budget_ms: integer?}? Options
--- @param callback fun(matrix: number[][])? Callback for async mode
--- @return number[][]? matrix Returns nil in async mode; matrix[i][j] = similarity between embeddings[i] and embeddings[j]
function M.similarity_matrix(embeddings, opts, callback)
  opts = opts or {}
  local time_budget_ms = opts.time_budget_ms or 50

  local n = #embeddings
  if n == 0 then
    local result = {}
    if callback then
      callback(result)
      return nil
    else
      return result
    end
  end

  local get_magnitude = make_get_magnitude(embeddings)
  local function compute_similarity(i, j)
    local mag_i = get_magnitude(i)
    local mag_j = get_magnitude(j)

    if mag_i == 0 or mag_j == 0 then
      return 0
    end

    local emb_i = embeddings[i]
    local emb_j = embeddings[j]
    local dot = dot_product(emb_i, emb_j)
    return dot / (mag_i * mag_j)
  end

  if not callback then
    local matrix = {}
    for i = 1, n do
      matrix[i] = {}
      for j = 1, n do
        if i == j then
          matrix[i][j] = 1.0
        elseif i > j then
          matrix[i][j] = matrix[j][i]
        else
          matrix[i][j] = compute_similarity(i, j)
        end
      end
    end
    return matrix
  end

  local state = {
    i = 1,
    j = 1,
    matrix = {},
  }

  for i = 1, n do
    state.matrix[i] = {}
  end

  local function process_batch()
    local start_time = vim.loop.hrtime()
    local time_budget_ns = time_budget_ms * 1000000

    local should_yield = function()
      local elapsed_ns = vim.loop.hrtime() - start_time
      return elapsed_ns >= time_budget_ns
    end

    while state.i <= n do
      while state.j <= n do
        if state.i == state.j then
          state.matrix[state.i][state.j] = 1.0
        elseif state.i > state.j then
          state.matrix[state.i][state.j] = state.matrix[state.j][state.i]
        else
          state.matrix[state.i][state.j] = compute_similarity(state.i, state.j)
        end

        state.j = state.j + 1

        if should_yield() then
          break
        end
      end

      if state.j > n then
        state.i = state.i + 1
        state.j = 1
      end

      if should_yield() then
        break
      end
    end

    if state.i > n then
      callback(state.matrix)
    else
      vim.schedule(process_batch)
    end
  end

  process_batch()
  return nil
end

--- Find clusters of similar embeddings using a simple threshold-based approach.
--- Items with similarity >= threshold are grouped together.
--- Supports both sync and async modes.
---
--- @param embeddings number[][] List of embedding vectors
--- @param opts {threshold: number?, time_budget_ms: integer?}? Options
--- @param callback fun(clusters: integer[][])? Callback for async mode
--- @return integer[][]? clusters Returns nil in async mode; each cluster is a list of indices
function M.find_clusters(embeddings, opts, callback)
  opts = opts or {}
  local threshold = opts.threshold or 0.8
  local time_budget_ms = opts.time_budget_ms or 50

  local function process_matrix(matrix)
    local n = #embeddings
    local visited = {}
    local clusters = {}

    for i = 1, n do
      if not visited[i] then
        local cluster = { i }
        visited[i] = true

        for j = i + 1, n do
          if not visited[j] and matrix[i][j] >= threshold then
            table.insert(cluster, j)
            visited[j] = true
          end
        end

        table.insert(clusters, cluster)
      end
    end

    if callback then
      callback(clusters)
    else
      return clusters
    end
  end

  if callback then
    M.similarity_matrix(embeddings, { time_budget_ms = time_budget_ms }, process_matrix)
    return nil
  else
    local matrix = M.similarity_matrix(embeddings, { time_budget_ms = time_budget_ms })
    return process_matrix(matrix)
  end
end

return M
