-- No-parens function call with table
local function sum(t)
    return t.a + t.b
end
return sum {a=10, b=20}
-- expect: 30
