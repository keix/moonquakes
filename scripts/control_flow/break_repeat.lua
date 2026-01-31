-- Break in repeat loop

function test()
    local i = 0
    repeat
        i = i + 1
        if i == 3 then
            break
        end
    until false
    return i
end

return test()
