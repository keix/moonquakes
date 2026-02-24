//! GC Sweep & Free
//!
//! Responsibilities:
//!   - Sweep unreachable (white) objects
//!   - Free object memory and update accounting
//!   - Handle per-type deallocation rules

const object = @import("object.zig");
const GCObject = object.GCObject;
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;
const UpvalueObject = object.UpvalueObject;
const ProtoObject = object.ProtoObject;
const UserdataObject = object.UserdataObject;
const ThreadObject = object.ThreadObject;
const Upvaldesc = object.Upvaldesc;
const Instruction = @import("../../compiler/opcodes.zig").Instruction;
const TValue = @import("../value.zig").TValue;

/// Sweep phase: free all unmarked (white) objects
/// Uses flip mark scheme - no need to clear marks (flipMark handles that)
pub fn sweep(self: anytype) void {
    var prev: ?*GCObject = null;
    var current = self.objects;

    while (current) |obj| {
        if (self.isMarked(obj)) {
            // Keep object - mark is preserved (flip mark scheme)
            // Clear gray state for next cycle
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
                self.bytes_allocated -= proto_obj.upvalues.len * @sizeOf(Upvaldesc);
                self.allocator.free(@constCast(proto_obj.upvalues));
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
    }
}
