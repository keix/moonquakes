-- FizzBuzz Demo
-- Classic programming challenge

print("=== FizzBuzz 1-30 ===")
print("")

for i = 1, 30 do
    if i % 15 == 0 then
        print("FizzBuzz")
    elseif i % 3 == 0 then
        print("Fizz")
    elseif i % 5 == 0 then
        print("Buzz")
    else
        print(i)
    end
end
