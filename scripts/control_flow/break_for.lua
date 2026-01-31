-- Break in for loop test

function test()
    local sum = 0
    for i = 1, 10 do
        if i > 3 then
            break
        end
        sum = sum + i
    end
    return sum
end

return test()
