-- FizzBuzz alternative pattern
-- Tests: complex conditional logic with else-heavy structure
for i = 1, 15 do
    if i % 15 == 0 then
        print("skip")
    elseif i % 3 == 0 then
        print("skip")
    elseif i % 5 == 0 then
        print("skip")
    else
        print(i)
    end
end

return "Alternative FizzBuzz complete"