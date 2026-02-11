-- Test print(tostring(x)) without metatable
print(tostring("hello"))
-- expect: hello
print(tostring(123))
-- expect: 123
