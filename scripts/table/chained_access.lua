function test()
    local t = {x = 10, y = 20}
    local key = "y"
    return t.x + t["y"]
end
return test()
