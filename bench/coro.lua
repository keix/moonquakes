-- Coroutine producer/consumer pipeline.
local function producer(n)
  return coroutine.create(function()
    for i = 1, n do
      coroutine.yield(i)
    end
  end)
end

local function filter(prod)
  return coroutine.create(function()
    while true do
      local ok, v = coroutine.resume(prod)
      if not ok or v == nil then break end
      coroutine.yield(v * 2 + 1)
    end
  end)
end

local n = 300000
local pipe = filter(producer(n))
local sum = 0
while true do
  local ok, v = coroutine.resume(pipe)
  if not ok or v == nil then break end
  sum = sum + v
end
print(sum)
