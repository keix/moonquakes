-- Test os.execute and os.exit

-- Test 1: Check shell availability
print("Test 1: Check shell availability")
local has_shell = os.execute()
print("Shell available: " .. tostring(has_shell))

-- Test 2: Execute successful command
print("\nTest 2: Execute 'echo hello'")
local ok, how, code = os.execute("echo hello")
print("ok: " .. tostring(ok))
print("how: " .. tostring(how))
print("code: " .. tostring(code))

-- Test 3: Execute failing command
print("\nTest 3: Execute 'exit 42'")
local ok2, how2, code2 = os.execute("exit 42")
print("ok: " .. tostring(ok2))
print("how: " .. tostring(how2))
print("code: " .. tostring(code2))

-- Test 4: Execute non-existent command
print("\nTest 4: Execute non-existent command")
local ok3, how3, code3 = os.execute("nonexistent_command_xyz123")
print("ok: " .. tostring(ok3))
print("how: " .. tostring(how3))
print("code: " .. tostring(code3))

-- Test 5: Capture output (not directly, but verify command runs)
print("\nTest 5: Execute 'ls /' (runs but no output capture)")
local ok4, how4, code4 = os.execute("ls / > /dev/null")
print("ok: " .. tostring(ok4))
print("how: " .. tostring(how4))
print("code: " .. tostring(code4))

print("\nos.execute tests completed!")
