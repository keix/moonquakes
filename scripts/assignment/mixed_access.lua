-- Mixed field and index assignment

function test()
    local t = { data = {} }
    local key = "value"
    t.data[key] = 50
    return t.data.value
end

return test()
