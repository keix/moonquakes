const std = @import("std");
const VM = @import("vm.zig").VM;
const TValue = @import("../runtime/value.zig").TValue;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;

/// Result of executing a single instruction.
/// Controls VM's main loop behavior.
pub const ExecuteResult = union(enum) {
    /// Normal instruction completed. Same frame, proceed to next.
    Continue,

    /// Frame changed (CALL pushed, RETURN popped). Restart loop with new ci.
    LoopContinue,

    /// Main function returned. Exit VM with this value.
    ReturnVM: VM.ReturnValue,
};

/// Execute a single instruction.
/// Called by VM's execute() loop after fetch.
///
/// Phase 1: Empty shell (unreachable)
/// Phase 2: Will contain full switch statement
pub fn do(vm: *VM, inst: Instruction) !ExecuteResult {
    _ = vm;
    _ = inst;
    // Phase 1: This function is not yet called.
    // When Phase 2 begins, the switch statement will be moved here.
    unreachable;
}
