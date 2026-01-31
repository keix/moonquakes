-- Final break test

function test(n)
    for i = 1, 100 do
        if i == n then
            break
        end
    end
    return n
end

return test(5)
