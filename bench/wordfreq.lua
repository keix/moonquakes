-- Word frequency via gmatch + table counting + sort: string/table mix.
local words = {
  "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog",
  "pack", "my", "box", "with", "five", "dozen", "liquor", "jugs",
}
local parts = {}
for i = 1, 12000 do
  parts[#parts + 1] = words[(i * 7) % #words + 1]
end
local text = table.concat(parts, " ")

local total = 0
for round = 1, 40 do
  local counts = {}
  for w in text:gmatch("%a+") do
    counts[w] = (counts[w] or 0) + 1
  end
  local keys = {}
  for k in pairs(counts) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    total = total + counts[k]
  end
end
print(total)
