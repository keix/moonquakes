function test(n)
    repeat
        if n > 5 then
            return n
        end
    until n > 0
    return 0
end
return test(10)
