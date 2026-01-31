-- Add with loop variable (2 iterations)

function test()
    local x = 0
    for i = 1, 2 do
        x = x + i
    end
    return x
end

return test()
