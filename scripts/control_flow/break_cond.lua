-- Break with condition test

function test()
    for i = 1, 10 do
        if i == 2 then
            break
        end
    end
    return 99
end

return test()
