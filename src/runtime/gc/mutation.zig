//! GC-visible mutation helpers.
//!
//! All writes that can create references between GC objects should go through
//! these helpers so barrier policy stays centralized.

const object = @import("object.zig");
const TableObject = object.TableObject;
const UserdataObject = object.UserdataObject;
const UpvalueObject = object.UpvalueObject;
const FileObject = object.FileObject;
const ThreadObject = object.ThreadObject;
const StringObject = object.StringObject;
const GCObject = object.GCObject;
const TValue = @import("../value.zig").TValue;

pub fn tableSet(gc: anytype, table: *TableObject, key: TValue, value: TValue) !void {
    try table.set(key, value);
    gc.barrierBackValue(&table.header, value);
}

pub fn tableSetMetatable(gc: anytype, table: *TableObject, new_mt: ?*TableObject) void {
    table.metatable = new_mt;
    if (new_mt) |mt| {
        gc.barrierBack(&table.header, &mt.header);
    }
}

pub fn userdataSetMetatable(gc: anytype, ud: *UserdataObject, new_mt: ?*TableObject) void {
    ud.metatable = new_mt;
    if (new_mt) |mt| {
        gc.barrierBack(&ud.header, &mt.header);
    }
}

pub fn initClosedUpvalue(gc: anytype, upvalue: *UpvalueObject, value: TValue) void {
    upvalue.closed = value;
    upvalue.location = &upvalue.closed;
    gc.barrierBackValue(&upvalue.header, value);
}

pub fn upvalueSet(gc: anytype, upvalue: *UpvalueObject, value: TValue) void {
    upvalue.set(value);
    if (upvalue.isClosed()) {
        gc.barrierBackValue(&upvalue.header, value);
    }
}

pub fn fileSetMetatable(gc: anytype, file_obj: *FileObject, mt: ?*TableObject) void {
    file_obj.metatable = mt;
    if (mt) |table| {
        gc.barrierBack(&file_obj.header, &table.header);
    }
}

pub fn fileSetStringRef(gc: anytype, file_obj: *FileObject, slot: *?*StringObject, value: ?*StringObject) void {
    slot.* = value;
    if (value) |str| {
        gc.barrierBack(&file_obj.header, &str.header);
    }
}

pub fn threadSetEntryFunc(gc: anytype, thread: *ThreadObject, entry_func: ?*GCObject) void {
    thread.entry_func = entry_func;
    if (entry_func) |func_obj| {
        gc.barrierBack(&thread.header, func_obj);
    }
}
