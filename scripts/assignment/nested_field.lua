-- Nested table field assignment

function test()
    local t = { inner = {} }
    t.inner.value = 50
    t.inner.other = 25
    return t.inner.value + t.inner.other
end

return test()
