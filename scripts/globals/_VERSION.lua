-- Test _VERSION

assert(type(_VERSION) == "string", "_VERSION should be a string")
-- Check that _VERSION starts with "Moonquakes"
assert(string.sub(_VERSION, 1, 10) == "Moonquakes", "_VERSION should start with 'Moonquakes'")

print("_VERSION test passed: " .. _VERSION)
