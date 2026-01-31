-- Unary minus precedence test: -2^2 = -(2^2) = -4, not (-2)^2 = 4

function test()
    return -2 ^ 2
end

return test()
