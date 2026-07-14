-- mandelbrot (benchmarks-game style, reduced): float inner loop with
-- early break + bitwise accumulation (SHL/BOR/BXOR/BAND coverage).
local N = 400
local sum = 0
for y = 0, N - 1 do
  local ci = 2 * y / N - 1
  local bits = 0
  local acc = 0
  for x = 0, N - 1 do
    local cr = 2 * x / N - 1.5
    local zr, zi = 0.0, 0.0
    local inside = 1
    for i = 1, 50 do
      local zr2 = zr * zr
      local zi2 = zi * zi
      if zr2 + zi2 > 4.0 then
        inside = 0
        break
      end
      zi = 2 * zr * zi + ci
      zr = zr2 - zi2 + cr
    end
    bits = ((bits << 1) | inside) & 0xFFFFFFFF
    if x % 8 == 7 then
      acc = acc ~ bits
      bits = 0
    end
  end
  sum = (sum + acc) & 0xFFFFFFFF
end
print(sum)
