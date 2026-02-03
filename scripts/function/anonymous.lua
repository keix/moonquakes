-- Anonymous function test

function test()
    local add = function(a, b)
        return a + b
    end
    return add(10, 20)
end

return test()
