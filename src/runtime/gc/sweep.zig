//! GC Sweep & Free
//!
//! Responsibilities:
//!   - Sweep unreachable (white) objects
//!   - Free object memory and update accounting
//!   - Handle per-type deallocation rules

const std = @import("std");
const object = @import("object.zig");
const GCObject = object.GCObject;
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;
const ObjectGeneration = object.ObjectGeneration;
const UpvalueObject = object.UpvalueObject;
const ProtoObject = object.ProtoObject;
const UserdataObject = object.UserdataObject;
const ThreadObject = object.ThreadObject;
const FileObject = object.FileObject;
const Upvaldesc = object.Upvaldesc;
const Instruction = @import("../../compiler/opcodes.zig").Instruction;
const TValue = @import("../value.zig").TValue;

fn collectsInCurrentCycle(self: anytype, obj: *const GCObject) bool {
    return self.current_cycle_kind == .major or obj.generation != .old;
}

/// Sweep phase: free all unmarked (white) objects
/// Uses flip mark scheme - no need to clear marks (flipMark handles that)
pub fn sweep(self: anytype) void {
    var prev: ?*GCObject = null;
    var current = self.objects;

    while (current) |obj| {
        if (!collectsInCurrentCycle(self, obj) or self.isMarked(obj)) {
            // Keep object - mark is preserved (flip mark scheme)
            // Clear gray state for next cycle
            if (!collectsInCurrentCycle(self, obj)) {
                // Old objects skipped by a minor cycle still need their mark bit
                // normalized to the current color so the next major flip makes
                // them white again.
                obj.mark_bit = self.current_mark;
            }
            obj.in_gray = false;
            obj.gray_next = null;
            prev = obj;
            current = obj.next;
        } else {
            // Free unmarked (white) object
            const next = obj.next;

            if (prev) |p| {
                p.next = next;
            } else {
                self.objects = next;
            }

            freeObject(self, obj);
            current = next;
        }
    }
}

/// Sweep up to `budget` objects from the current cursor.
/// Returns true when the sweep phase is fully complete.
pub fn sweepStep(self: anytype, budget: usize) bool {
    var remaining = budget;

    while (remaining > 0) {
        const obj = self.sweep_cursor orelse return true;
        remaining -= 1;

        if (!collectsInCurrentCycle(self, obj) or self.isMarked(obj)) {
            if (!collectsInCurrentCycle(self, obj)) {
                obj.mark_bit = self.current_mark;
            }
            obj.in_gray = false;
            obj.gray_next = null;
            self.sweep_prev = obj;
            self.sweep_cursor = obj.next;
            continue;
        }

        const next = obj.next;
        if (self.sweep_prev) |prev| {
            prev.next = next;
        } else {
            self.objects = next;
        }

        freeObject(self, obj);
        self.sweep_cursor = next;
    }

    return self.sweep_cursor == null;
}

pub fn finishSweepCycle(self: anytype) void {
    var current = self.objects;
    while (current) |obj| {
        obj.generation = switch (self.current_cycle_kind) {
            .major => .old,
            .minor => switch (obj.generation) {
                .young => .survival,
                .survival, .old => .old,
            },
        };
        current = obj.next;
    }

    switch (self.current_cycle_kind) {
        .major => {
            self.generational_minor_cycles = 0;
        },
        .minor => if (self.generational_minor_cycles < std.math.maxInt(u8)) {
            self.generational_minor_cycles += 1;
        },
    }

    self.gc_state = .idle;
    self.sweep_cursor = null;
    self.sweep_prev = null;
    self.next_gc = @max(
        @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.bytes_allocated)) * self.gc_multiplier)),
        self.gc_min_threshold,
    );
}

/// Free a GC object and update accounting
fn freeObject(self: anytype, obj: *GCObject) void {
    // For strings, remove from intern table before freeing
    if (obj.type == .string) {
        const str_obj: *StringObject = @fieldParentPtr("header", obj);
        _ = self.strings.remove(str_obj.asSlice());
    }
    freeObjectFinal(self, obj);
}

/// Free object without updating intern table (for use during deinit)
pub fn freeObjectFinal(self: anytype, obj: *GCObject) void {
    switch (obj.type) {
        .string => {
            const str_obj: *StringObject = @fieldParentPtr("header", obj);
            const size = @sizeOf(StringObject) + str_obj.len;
            self.bytes_allocated -= size;
            const memory = @as([*]u8, @ptrCast(str_obj))[0..size];
            self.allocator.free(memory);
        },
        .table => {
            const table_obj: *TableObject = @fieldParentPtr("header", obj);
            table_obj.deinit(); // Free hash_part
            const size = @sizeOf(TableObject);
            self.bytes_allocated -= size;
            const memory = @as([*]u8, @ptrCast(table_obj))[0..size];
            self.allocator.free(memory);
        },
        .closure => {
            const closure_obj: *ClosureObject = @fieldParentPtr("header", obj);
            // Free upvalues array if allocated
            if (closure_obj.upvalues.len > 0) {
                self.bytes_allocated -= closure_obj.upvalues.len * @sizeOf(*UpvalueObject);
                self.allocator.free(closure_obj.upvalues);
            }
            const size = @sizeOf(ClosureObject);
            self.bytes_allocated -= size;
            const memory = @as([*]u8, @ptrCast(closure_obj))[0..size];
            self.allocator.free(memory);
        },
        .native_closure => {
            const native_obj: *NativeClosureObject = @fieldParentPtr("header", obj);
            const size = @sizeOf(NativeClosureObject);
            self.bytes_allocated -= size;
            const memory = @as([*]u8, @ptrCast(native_obj))[0..size];
            self.allocator.free(memory);
        },
        .upvalue => {
            const upval_obj: *UpvalueObject = @fieldParentPtr("header", obj);
            const size = @sizeOf(UpvalueObject);
            self.bytes_allocated -= size;
            const memory = @as([*]u8, @ptrCast(upval_obj))[0..size];
            self.allocator.free(memory);
        },
        .userdata => {
            const ud_obj: *UserdataObject = @fieldParentPtr("header", obj);
            const size = UserdataObject.allocationSize(ud_obj.size, ud_obj.nuvalue);
            self.bytes_allocated -= size;
            const memory = @as([*]u8, @ptrCast(ud_obj))[0..size];
            self.allocator.free(memory);
        },
        .proto => {
            const proto_obj: *ProtoObject = @fieldParentPtr("header", obj);
            // Free arrays allocated by materialize
            if (proto_obj.k.len > 0) {
                self.bytes_allocated -= proto_obj.k.len * @sizeOf(TValue);
                self.allocator.free(@constCast(proto_obj.k));
            }
            if (proto_obj.code.len > 0) {
                self.bytes_allocated -= proto_obj.code.len * @sizeOf(Instruction);
                self.allocator.free(@constCast(proto_obj.code));
            }
            if (proto_obj.protos.len > 0) {
                self.bytes_allocated -= proto_obj.protos.len * @sizeOf(*ProtoObject);
                self.allocator.free(@constCast(proto_obj.protos));
            }
            if (proto_obj.upvalues.len > 0) {
                for (proto_obj.upvalues) |upv| {
                    if (upv.name) |name| {
                        self.bytes_allocated -= name.len;
                        self.allocator.free(name);
                    }
                }
                self.bytes_allocated -= proto_obj.upvalues.len * @sizeOf(Upvaldesc);
                self.allocator.free(@constCast(proto_obj.upvalues));
            }
            if (proto_obj.local_reg_names.len > 0) {
                for (proto_obj.local_reg_names) |name_opt| {
                    if (name_opt) |name| {
                        self.bytes_allocated -= name.len;
                        self.allocator.free(name);
                    }
                }
                self.bytes_allocated -= proto_obj.local_reg_names.len * @sizeOf(?[]const u8);
                self.allocator.free(@constCast(proto_obj.local_reg_names));
            }
            if (proto_obj.source.len > 0) {
                self.bytes_allocated -= proto_obj.source.len;
                self.allocator.free(proto_obj.source);
            }
            if (proto_obj.lineinfo.len > 0) {
                self.bytes_allocated -= proto_obj.lineinfo.len * @sizeOf(u32);
                self.allocator.free(proto_obj.lineinfo);
            }
            // Free the ProtoObject itself
            const size = @sizeOf(ProtoObject);
            self.bytes_allocated -= size;
            const memory = @as([*]u8, @ptrCast(proto_obj))[0..size];
            self.allocator.free(memory);
        },
        .thread => {
            const thread_obj: *ThreadObject = @fieldParentPtr("header", obj);
            // Free VM memory if callback is set (coroutine threads only)
            // Main thread is freed by Runtime.deinit, not here
            if (thread_obj.free_vm) |free_fn| {
                free_fn(thread_obj.vm, self.allocator);
            }
            const size = @sizeOf(ThreadObject);
            self.bytes_allocated -= size;
            const memory = @as([*]u8, @ptrCast(thread_obj))[0..size];
            self.allocator.free(memory);
        },
        .file => {
            const file_obj: *FileObject = @fieldParentPtr("header", obj);
            // Close file and free buffer
            file_obj.deinit();
            const size = @sizeOf(FileObject);
            self.bytes_allocated -= size;
            const memory = @as([*]u8, @ptrCast(file_obj))[0..size];
            self.allocator.free(memory);
        },
    }
}
