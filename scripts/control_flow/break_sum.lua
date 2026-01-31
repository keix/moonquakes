-- Break sum test

function test()
    local sum = 0
    for i = 1, 10 do
        sum = sum + i
        if i == 3 then
            break
        end
    end
    return sum
end

return test()
