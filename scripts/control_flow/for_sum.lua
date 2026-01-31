-- For sum test (without break)

function test()
    local sum = 0
    for i = 1, 3 do
        sum = sum + i
    end
    return sum
end

return test()
