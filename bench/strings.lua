-- String building and formatting mix: concat, format, sub, find.
local total = 0
local lines = {}
for i = 1, 60000 do
  local line = string.format("id=%d name=%s value=%.3f", i, "item" .. (i % 100), i * 0.5)
  lines[#lines + 1] = line
end
local blob = table.concat(lines, "\n")
total = total + #blob

for round = 1, 30 do
  local n = 0
  local pos = 1
  while true do
    local s, e = blob:find("name=item7%f[%D]", pos)
    if not s then break end
    n = n + 1
    pos = e + 1
  end
  total = total + n
  total = total + #blob:sub(round * 100, round * 100 + 50)
end
print(total)
