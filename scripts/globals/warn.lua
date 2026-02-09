-- Test warn()
-- Note: warn outputs to stderr, so we just verify it doesn't crash

warn("Test warning message")
warn("Warning with number: ", 42)
warn("Multiple", " ", "parts")

print("warn test completed!")
