-- binary-trees (benchmarks-game style): allocation and GC pressure.
local function bottomup(depth)
  if depth > 0 then
    depth = depth - 1
    return { bottomup(depth), bottomup(depth) }
  end
  return { false, false }
end

local function check(tree)
  if tree[1] then
    return 1 + check(tree[1]) + check(tree[2])
  end
  return 1
end

local maxdepth = 14
local stretch = bottomup(maxdepth + 1)
local sum = check(stretch)
stretch = nil

local longlived = bottomup(maxdepth)

for depth = 4, maxdepth, 2 do
  local iterations = 1 << (maxdepth - depth + 4)
  for i = 1, iterations do
    sum = sum + check(bottomup(depth))
  end
end

print(sum + check(longlived))
