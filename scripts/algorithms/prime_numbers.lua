-- Simple divisibility test (current Moonquakes capabilities)
-- Tests: nested conditions, modulo operations
for i = 2, 20 do
    if i % 2 == 0 then
        if i % 3 == 0 then
            print("Divisible by 2 and 3")
        else
            print("Even number")
        end
    elseif i % 3 == 0 then
        print("Divisible by 3")
    elseif i % 5 == 0 then
        print("Divisible by 5")
    else
        print("Other number")
    end
end

return "Divisibility test complete"