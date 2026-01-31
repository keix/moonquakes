-- Break in while loop test

function test()
    local i = 0
    local sum = 0
    while i < 100 do
        i = i + 1
        if i > 5 then
            break
        end
        sum = sum + i
    end
    return sum
end

return test()
