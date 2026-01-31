-- Simple break in for

function test()
    for i = 1, 10 do
        if i == 3 then
            return i
        end
    end
    return 0
end

return test()
