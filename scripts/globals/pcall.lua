-- pcall test: protected function calls

-- Test 1: Successful call
local ok, result = pcall(tostring, 42)
assert(ok == true, "Expected ok to be true for successful call")
assert(result == "42", "Expected result to be '42'")
print("Test 1 passed: successful call returns true and result")

-- Test 2: Direct error call
local ok2, err = pcall(error, "test error message")
assert(ok2 == false, "Expected ok to be false for error call")
assert(err == "test error message", "Expected error message to match")
print("Test 2 passed: error() returns false and error message")

-- Test 3: Error in function
local function fail_func()
    error("function failed")
end
local ok3, err3 = pcall(fail_func)
assert(ok3 == false, "Expected ok to be false for failing function")
assert(err3 == "function failed", "Expected error message from function")
print("Test 3 passed: error in function returns false and message")

-- Test 4: Function with multiple return values
local function multi_return(a, b)
    return a + b, a * b
end
local ok4, sum, prod = pcall(multi_return, 3, 4)
assert(ok4 == true, "Expected ok to be true")
assert(sum == 7, "Expected sum to be 7")
print("Test 4 passed: multiple return values work")

-- Test 5: Nested pcall
local function outer()
    local ok, err = pcall(error, "inner error")
    if not ok then
        error("outer caught: " .. err)
    end
end
local ok5, err5 = pcall(outer)
assert(ok5 == false, "Expected nested pcall to propagate error")
assert(err5 == "outer caught: inner error", "Expected combined error message")
print("Test 5 passed: nested pcall works correctly")

print("All pcall tests passed!")
