-- Float with concat test (ensure 1..2 doesn't break)

function test()
    local a = 1
    local b = 2
    return a .. b
end

return test()
