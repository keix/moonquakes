-- Simple break test

function test()
    local i = 0
    while true do
        i = i + 1
        if i == 3 then
            break
        end
    end
    return i
end

return test()
