-- Step 1: Test basic modulo and elseif
if 15 % 15 == 0 then
    return "FizzBuzz"
elseif 15 % 3 == 0 then
    return "Fizz"
elseif 15 % 5 == 0 then
    return "Buzz"
else
    return 15
end