-- Local variable example

function test()
    local a = 10
    local b = 20
    local c = a + b
    return c
end

print(test())

function calculate()
    local x = 5
    local y = 3
    local sum = x + y
    local diff = x - y
    local prod = x * y
    print(sum)
    print(diff)
    print(prod)
    return sum * diff * prod
end

print(calculate())

return 0
