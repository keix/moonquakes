-- Test __newindex with table fallback
local storage = {}
local mt = { __newindex = storage }

local proxy = { existing = "value" }
setmetatable(proxy, mt)

-- Updating existing key should work directly
proxy.existing = "updated"
assert(proxy.existing == "updated", "existing key update failed")

-- Setting new key should go to storage table
proxy.newkey = "newvalue"
assert(storage.newkey == "newvalue", "expected storage.newkey=newvalue")
assert(proxy.newkey == nil, "proxy should not have newkey directly")

print("__newindex table test passed")
