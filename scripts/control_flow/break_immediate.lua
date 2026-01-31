-- Immediate break test

function test()
    for i = 1, 10 do
        break
    end
    return 42
end

return test()
