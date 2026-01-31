-- Chained field assignment

function test()
    local a = { b = { c = {} } }
    a.b.c.value = 123
    return a.b.c.value
end

return test()
