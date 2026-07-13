-- spectral-norm (benchmarks-game style): float math + tight function calls.
local function A(i, j)
  local ij = i + j - 2
  return 1.0 / (ij * (ij + 1) * 0.5 + i)
end

local function Av(x, y, N)
  for i = 1, N do
    local a = 0
    for j = 1, N do
      a = a + x[j] * A(i, j)
    end
    y[i] = a
  end
end

local function Atv(x, y, N)
  for i = 1, N do
    local a = 0
    for j = 1, N do
      a = a + x[j] * A(j, i)
    end
    y[i] = a
  end
end

local function AtAv(x, y, t, N)
  Av(x, t, N)
  Atv(t, y, N)
end

local N = 300
local u, v, t = {}, {}, {}
for i = 1, N do
  u[i] = 1
end

for _ = 1, 10 do
  AtAv(u, v, t, N)
  AtAv(v, u, t, N)
end

local vBv, vv = 0, 0
for i = 1, N do
  vBv = vBv + u[i] * v[i]
  vv = vv + v[i] * v[i]
end
print(string.format("%.9f", math.sqrt(vBv / vv)))
