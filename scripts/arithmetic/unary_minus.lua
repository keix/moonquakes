-- Unary minus test

function test()
    local a = 10
    local b = -a
    local c = -5
    local d = -(-a)
    return b + c + d
end

return test()
