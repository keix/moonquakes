-- Single quote string test

function test()
    local a = 'hello'
    local b = "world"
    local c = "it's"
    local d = 'say "hi"'
    print(a, b, c, d)
    return a
end

return test()
