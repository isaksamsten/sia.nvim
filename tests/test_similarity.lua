local similarity = require("sia.similarity")
local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

T["sia.similarity"] = MiniTest.new_set()

-- Helper to check if two numbers are close (for floating point comparison)
local function is_close(a, b, tolerance)
  tolerance = tolerance or 0.0001
  return math.abs(a - b) < tolerance
end

T["sia.similarity"]["identical vectors"] = function()
  local v1 = { 1, 2, 3 }
  local v2 = { 1, 2, 3 }
  local score = similarity.cosine_similarity(v1, v2)
  eq(true, is_close(score, 1.0))
end

T["sia.similarity"]["orthogonal vectors"] = function()
  local v1 = { 1, 0, 0 }
  local v2 = { 0, 1, 0 }
  local score = similarity.cosine_similarity(v1, v2)
  eq(true, is_close(score, 0.0))
end

T["sia.similarity"]["opposite vectors"] = function()
  local v1 = { 1, 2, 3 }
  local v2 = { -1, -2, -3 }
  local score = similarity.cosine_similarity(v1, v2)
  eq(true, is_close(score, -1.0))
end

T["sia.similarity"]["same direction different magnitude"] = function()
  local v1 = { 1, 2, 3 }
  local v2 = { 2, 4, 6 }
  local score = similarity.cosine_similarity(v1, v2)
  eq(true, is_close(score, 1.0))
end

T["sia.similarity"]["empty vectors"] = function()
  local score = similarity.cosine_similarity({}, {})
  eq(0, score)
end

T["sia.similarity"]["different length vectors"] = function()
  local v1 = { 1, 2, 3 }
  local v2 = { 1, 2 }
  local score = similarity.cosine_similarity(v1, v2)
  eq(0, score)
end

T["sia.similarity"]["zero magnitude vector"] = function()
  local v1 = { 1, 2, 3 }
  local v2 = { 0, 0, 0 }
  local score = similarity.cosine_similarity(v1, v2)
  eq(0, score)
end

T["sia.similarity"]["find_similar sync - basic"] = function()
  local query = { 1, 2, 3 }
  local targets = {
    { 1, 2, 3 }, -- Identical (score = 1.0)
    { 2, 4, 6 }, -- Same direction (score = 1.0)
    { 1, 0, 0 }, -- Different direction
    { -1, -2, -3 }, -- Opposite (score = -1.0)
  }

  local results = similarity.find_similar(query, targets, { top_k = 4 })

  eq(4, #results)
  -- Should be sorted by score descending
  eq(true, results[1].score >= results[2].score)
  eq(true, results[2].score >= results[3].score)
  eq(true, results[3].score >= results[4].score)

  -- Check top results are the most similar
  eq(true, is_close(results[1].score, 1.0))
  eq(true, is_close(results[2].score, 1.0))
end

T["sia.similarity"]["find_similar sync - top_k limit"] = function()
  local query = { 1, 0, 0 }
  local targets = {}
  for i = 1, 10 do
    targets[i] = { math.random(), math.random(), math.random() }
  end

  local results = similarity.find_similar(query, targets, { top_k = 3 })

  eq(3, #results)
  eq(true, results[1].score >= results[2].score)
  eq(true, results[2].score >= results[3].score)
end

T["sia.similarity"]["find_similar sync - empty query"] = function()
  local results = similarity.find_similar({}, { { 1, 2, 3 } }, {})
  eq(0, #results)
end

T["sia.similarity"]["find_similar sync - empty targets"] = function()
  local results = similarity.find_similar({ 1, 2, 3 }, {}, {})
  eq(0, #results)
end

T["sia.similarity"]["find_similar sync - returns indices"] = function()
  local query = { 1, 0, 0 }
  local targets = {
    { 0, 1, 0 }, -- Less similar
    { 1, 0, 0 }, -- Identical
    { 0, 0, 1 }, -- Less similar
  }

  local results = similarity.find_similar(query, targets, { top_k = 3 })

  eq(3, #results)
  eq(2, results[1].index)
  eq(true, is_close(results[1].score, 1.0))
end

T["sia.similarity"]["similarity_matrix sync - basic"] = function()
  local embeddings = {
    { 1, 0, 0 },
    { 0, 1, 0 },
    { 1, 1, 0 },
  }

  local matrix = similarity.similarity_matrix(embeddings)

  eq(3, #matrix)
  eq(3, #matrix[1])

  eq(true, is_close(matrix[1][1], 1.0))
  eq(true, is_close(matrix[2][2], 1.0))
  eq(true, is_close(matrix[3][3], 1.0))

  eq(true, is_close(matrix[1][2], matrix[2][1]))
  eq(true, is_close(matrix[1][3], matrix[3][1]))
  eq(true, is_close(matrix[2][3], matrix[3][2]))

  eq(true, is_close(matrix[1][2], 0.0))
end

T["sia.similarity"]["similarity_matrix sync - empty"] = function()
  local matrix = similarity.similarity_matrix({})
  eq(0, #matrix)
end

T["sia.similarity"]["similarity_matrix sync - single embedding"] = function()
  local matrix = similarity.similarity_matrix({ { 1, 2, 3 } })
  eq(1, #matrix)
  eq(1, #matrix[1])
  eq(true, is_close(matrix[1][1], 1.0))
end

T["sia.similarity"]["find_clusters sync - basic"] = function()
  local embeddings = {
    { 1, 0, 0 }, -- Cluster 1
    { 1.1, 0, 0 }, -- Cluster 1 (very similar to first)
    { 0, 1, 0 }, -- Cluster 2
    { 0, 1.1, 0 }, -- Cluster 2 (very similar to third)
  }

  local clusters = similarity.find_clusters(embeddings, { threshold = 0.9 })

  eq(2, #clusters)

  eq(true, #clusters[1] == 2 or #clusters[2] == 2)
end

T["sia.similarity"]["find_clusters sync - no clusters"] = function()
  local embeddings = {
    { 1, 0, 0 },
    { 0, 1, 0 },
    { 0, 0, 1 },
  }

  local clusters = similarity.find_clusters(embeddings, { threshold = 0.99 })

  eq(3, #clusters)
  eq(1, #clusters[1])
  eq(1, #clusters[2])
  eq(1, #clusters[3])
end

T["sia.similarity"]["find_clusters sync - single cluster"] = function()
  local embeddings = {
    { 1, 0, 0 },
    { 1, 0, 0 },
    { 1, 0, 0 },
  }

  local clusters = similarity.find_clusters(embeddings, { threshold = 0.99 })

  eq(1, #clusters)
  eq(3, #clusters[1])
end

T["sia.similarity"]["find_clusters sync - empty"] = function()
  local clusters = similarity.find_clusters({}, {})
  eq(0, #clusters)
end

T["sia.similarity async"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      T.child = MiniTest.new_child_neovim()
      T.child.restart({ "-u", "assets/minimal.lua" })
    end,
    post_once = function()
      T.child.stop()
    end,
  },
})

T["sia.similarity async"]["find_similar basic"] = function()
  local code = [[
    local similarity = require("sia.similarity")
    local completed = false

    local query = { 1, 2, 3 }
    local targets = {
      { 1, 2, 3 },
      { 2, 4, 6 },
      { 1, 0, 0 },
      { -1, -2, -3 },
    }

    similarity.find_similar(query, targets, { top_k = 3, callback=function(results)
      _G.result = results
      completed = true
    end})

    vim.wait(1000, function() return completed end, 10)
    _G.completed = completed
  ]]

  T.child.lua(code)
  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(3, #result)
  eq(true, result[1].score >= result[2].score)
  eq(true, result[1].score >= 0.99)
end

T["sia.similarity async"]["find_similar large dataset"] = function()
  local code = [[
    local similarity = require("sia.similarity")
    local completed = false

    local query = { 1, 0, 0 }
    local targets = {}
    for i = 1, 1000 do
      targets[i] = { math.random(), math.random(), math.random() }
    end
    targets[500] = { 0.99, 0.01, 0.01 }

    similarity.find_similar(query, targets, { top_k = 5, time_budget_ms = 50, callback=function(results)
      _G.result = results
      completed = true
    end})

    vim.wait(5000, function() return completed end, 50)
    _G.completed = completed
  ]]

  T.child.lua(code)
  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(5, #result)

  local found_500 = false
  for _, r in ipairs(result) do
    if r.index == 500 then
      found_500 = true
      break
    end
  end
  eq(true, found_500)
end

T["sia.similarity async"]["similarity_matrix basic"] = function()
  local code = [[
    local similarity = require("sia.similarity")
    local completed = false

    local embeddings = {
      { 1, 0, 0 },
      { 0, 1, 0 },
      { 1, 1, 0 },
    }

    similarity.similarity_matrix(embeddings, {}, function(matrix)
      _G.result = matrix
      completed = true
    end)

    vim.wait(1000, function() return completed end, 10)
    _G.completed = completed
  ]]

  T.child.lua(code)
  local completed = T.child.lua_get("_G.completed")
  local matrix = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(3, #matrix)
  eq(3, #matrix[1])

  eq(true, math.abs(matrix[1][1] - 1.0) < 0.001)
  eq(true, math.abs(matrix[2][2] - 1.0) < 0.001)
  eq(true, math.abs(matrix[3][3] - 1.0) < 0.001)

  eq(true, math.abs(matrix[1][2] - matrix[2][1]) < 0.001)
end

T["sia.similarity async"]["similarity_matrix large dataset"] = function()
  local code = [[
    local similarity = require("sia.similarity")
    local completed = false

    local embeddings = {}
    for i = 1, 100 do
      embeddings[i] = { math.random(), math.random(), math.random() }
    end

    similarity.similarity_matrix(embeddings, { time_budget_ms = 50 }, function(matrix)
      _G.result = matrix
      completed = true
    end)

    vim.wait(10000, function() return completed end, 50)
    _G.completed = completed
  ]]

  T.child.lua(code)
  local completed = T.child.lua_get("_G.completed")
  local matrix = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(100, #matrix)

  for i = 1, 100 do
    eq(true, math.abs(matrix[i][i] - 1.0) < 0.001)
  end

  eq(true, math.abs(matrix[1][2] - matrix[2][1]) < 0.001)
  eq(true, math.abs(matrix[10][20] - matrix[20][10]) < 0.001)
  eq(true, math.abs(matrix[50][75] - matrix[75][50]) < 0.001)
end

T["sia.similarity async"]["find_clusters basic"] = function()
  local code = [[
    local similarity = require("sia.similarity")
    local completed = false

    local embeddings = {
      { 1, 0, 0 },
      { 1, 0, 0 },
      { 0, 1, 0 },
      { 0, 1, 0 },
    }

    similarity.find_clusters(embeddings, { threshold = 0.99 }, function(clusters)
      _G.result = clusters
      completed = true
    end)

    vim.wait(1000, function() return completed end, 10)
    _G.completed = completed
  ]]

  T.child.lua(code)
  local completed = T.child.lua_get("_G.completed")
  local clusters = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(2, #clusters)
  eq(2, #clusters[1])
  eq(2, #clusters[2])
end

T["sia.similarity async"]["results match sync version"] = function()
  local code = [[
    local similarity = require("sia.similarity")
    local completed = false

    local query = { 1, 2, 3, 4, 5 }
    local targets = {}
    for i = 1, 50 do
      targets[i] = { math.random(), math.random(), math.random(), math.random(), math.random() }
    end

    local sync_result = similarity.find_similar(query, targets, { top_k = 5 })

    similarity.find_similar(query, targets, { top_k = 5, callback=function(async_result)
      _G.async_result = async_result
      completed = true
    end})

    vim.wait(2000, function() return completed end, 20)
    _G.completed = completed
    _G.sync_result = sync_result
  ]]

  T.child.lua(code)
  local completed = T.child.lua_get("_G.completed")
  local async_result = T.child.lua_get("_G.async_result")
  local sync_result = T.child.lua_get("_G.sync_result")

  eq(true, completed)
  eq(#sync_result, #async_result)

  for i = 1, #sync_result do
    eq(sync_result[i].index, async_result[i].index)
    eq(true, math.abs(sync_result[i].score - async_result[i].score) < 0.001)
  end
end

T["sia.similarity async"]["empty query"] = function()
  local code = [[
    local similarity = require("sia.similarity")
    local completed = false

    similarity.find_similar({}, { { 1, 2, 3 } }, {callback=function(results)
      _G.result = results
      completed = true
    end})

    vim.wait(1000, function() return completed end, 10)
    _G.completed = completed
  ]]

  T.child.lua(code)
  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(0, #result)
end

T["sia.similarity async"]["empty targets"] = function()
  local code = [[
    local similarity = require("sia.similarity")
    local completed = false

    similarity.find_similar({ 1, 2, 3 }, {}, {callback=function(results)
      _G.result = results
      completed = true
    end})

    vim.wait(1000, function() return completed end, 10)
    _G.completed = completed
  ]]

  T.child.lua(code)
  local completed = T.child.lua_get("_G.completed")
  local result = T.child.lua_get("_G.result")

  eq(true, completed)
  eq(0, #result)
end

return T
