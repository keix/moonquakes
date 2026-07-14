-- String concatenation: naive .. accumulation and multi-operand chains
-- with number-to-string conversion (CONCAT opcode coverage).
local total = 0
for round = 1, 150 do
  local s = ""
  for i = 1, 400 do
    s = s .. i .. ","
  end
  total = total + #s
end
for round = 1, 100000 do
  local t = "id" .. "-" .. round .. "-" .. (round + 1) .. "-end"
  total = total + #t
end
print(total)
