-- Test labels after goto
print("Test: Labels after goto")

local function dispatch(op)
  local result = nil

  if op == "a" then goto label_a end
  if op == "b" then goto label_b end
  goto label_done

  ::label_a::
  result = "got a"
  goto label_done

  ::label_b::
  result = "got b"

  ::label_done::
  return result
end

print("dispatch(a) = " .. tostring(dispatch("a")))
print("dispatch(b) = " .. tostring(dispatch("b")))
print("dispatch(c) = " .. tostring(dispatch("c")))
