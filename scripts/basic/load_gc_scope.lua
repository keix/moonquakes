-- GC integration test: closure disposal
-- Verifies Proto is properly in GC graph after scope exit

do
  local f = load("return 99")
end

collectgarbage()
print("gc after scope")
-- expect: gc after scope
