-- Return loop variable

function test()
    for i = 1, 3 do
        return i
    end
    return 0
end

return test()
