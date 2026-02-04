-- Hex float test
local a = 0x1p4      -- 1 * 2^4 = 16
local b = 0x1.0      -- 1.0
local c = 0x1.8p1    -- 1.5 * 2^1 = 3
local d = 0x1.8p-1   -- 1.5 * 2^-1 = 0.75
local e = 0xAp0      -- 10 * 2^0 = 10
return a + b + c + d + e
-- expect: 30.75
