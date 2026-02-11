-- GC integration test: repeated load
-- Verifies Proto GC is stable under repeated allocation

for i = 1, 1000 do
  local f = load("return 123")
  f()
end

collectgarbage()
print("loop load done")
-- expect: loop load done
