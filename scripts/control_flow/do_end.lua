-- do ... end block scope test

function test()
    local x = 10
    do
        local x = 20
        -- inner x shadows outer x
    end
    -- outer x should still be 10
    return x
end

return test()
