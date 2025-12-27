for i = 3, 3 do
    if i % 15 == 0 then
        return "FizzBuzz"
    elseif i % 3 == 0 then
        return "Fizz"
    else
        return i
    end
end