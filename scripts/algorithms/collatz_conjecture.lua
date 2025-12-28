-- Simple number classification
-- Tests: complex conditional logic, range checking
for i = 1, 15 do
    if i == 1 then
        print("one")
    elseif i % 2 == 0 then
        if i % 4 == 0 then
            print("divisible by 4")
        else
            print("even")
        end
    else
        print("odd")
    end
end

