-- Test _VERSION

assert(type(_VERSION) == "string", "_VERSION should be a string")
assert(_VERSION == "Moonquakes 0.1.0", "_VERSION should be 'Lua 5.4'")

print("_VERSION test passed!")
