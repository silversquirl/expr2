const std = @import("std");
const x86 = @import("x86");

const Token = union(enum) {
    op: u8,
    int: i64,
};

fn compile(w: anytype, toks: []const Token) !void {
    const m = x86.Machine.init(.x64);

    const rax = x86.Operand.register(.RAX);
    const rdi = x86.Operand.register(.RDI);
    const rbp = x86.Operand.register(.RBP);
    const rsp = x86.Operand.register(.RSP);

    // Prelude
    {
        const i = try m.build1(.PUSH, rbp);
        try w.writeAll(i.asSlice());
    }
    {
        const i = try m.build2(.MOV, rbp, rsp);
        try w.writeAll(i.asSlice());
    }

    var stackSize: u32 = 0;

    for (toks) |tok| {
        switch (tok) {
            .int => |x| {
                {
                    const val = x86.Operand.immediateSigned64(x);
                    const i = try m.build2(.MOV, rax, val);
                    try w.writeAll(i.asSlice());
                }
                {
                    const i = try m.build1(.PUSH, rax);
                    try w.writeAll(i.asSlice());
                }
                stackSize += 1;
            },

            .op => |operator| {
                {
                    const i = try m.build1(.POP, rdi);
                    try w.writeAll(i.asSlice());
                }
                {
                    const i = try m.build1(.POP, rax);
                    try w.writeAll(i.asSlice());
                }

                switch (operator) {
                    '+' => {
                        const i = try m.build2(.ADD, rax, rdi);
                        try w.writeAll(i.asSlice());
                    },
                    '-' => {
                        const i = try m.build2(.SUB, rax, rdi);
                        try w.writeAll(i.asSlice());
                    },
                    '*' => {
                        const i = try m.build2(.IMUL, rax, rdi);
                        try w.writeAll(i.asSlice());
                    },

                    '/' => {
                        {
                            const i = try m.build0(.CDQ);
                            try w.writeAll(i.asSlice());
                        }
                        {
                            const i = try m.build1(.IDIV, rdi);
                            try w.writeAll(i.asSlice());
                        }
                    },

                    else => return error.InvalidOperator,
                }

                {
                    const i = try m.build1(.PUSH, rax);
                    try w.writeAll(i.asSlice());
                }

                stackSize -= 1;
            },
        }
    }

    if (stackSize < 1) {
        return error.StackUnderflow;
    } else if (stackSize > 1) {
        return error.UnusedOperands;
    }

    // Teardown
    {
        const i = try m.build1(.POP, rax);
        try w.writeAll(i.asSlice());
    }
    {
        const i = try m.build0(.LEAVE);
        try w.writeAll(i.asSlice());
    }
    {
        const i = try m.build0(.RET);
        try w.writeAll(i.asSlice());
    }
}

const JitResult = struct {
    allocator: *std.mem.Allocator,
    code: []align(std.mem.page_size) u8,
    func: fn () callconv(.C) i64,

    pub fn deinit(self: JitResult) void {
        std.os.mprotect(self.code, std.os.PROT_READ | std.os.PROT_WRITE) catch {};
        self.allocator.free(self.code);
    }
};

fn jit(toks: []const Token) !JitResult {
    const allocator = std.heap.page_allocator;
    // FIXME: use ArrayListAligned. See ziglang/zig#8647
    var buf = try std.ArrayList(u8).initCapacity(allocator, std.mem.page_size);
    defer buf.deinit();

    try compile(buf.writer(), toks);

    var code = @alignCast(std.mem.page_size, buf.toOwnedSlice());
    errdefer allocator.free(code);
    code.len = alignup(usize, code.len, std.mem.page_size);
    try std.os.mprotect(code, std.os.PROT_READ | std.os.PROT_EXEC);

    return JitResult{
        .allocator = allocator,
        .code = code,
        .func = @ptrCast(fn () callconv(.C) i64, code.ptr),
    };
}

fn alignup(comptime T: type, x: T, a: T) T {
    return 1 +% ~(1 +% ~x & 1 +% ~a);
}

pub fn main() !void {
    const toks = &[_]Token{
        .{ .int = 1 },
        .{ .int = 3 },
        .{ .int = 4 },
        .{ .op = '+' },
        .{ .int = 2 },
        .{ .op = '/' },
        .{ .op = '+' },
        .{ .int = 12 },
        .{ .op = '*' },
    };
    const jitted = try jit(toks);
    defer jitted.deinit();
    const out = std.io.getStdOut().writer();
    try out.print("compiled\n", .{});
    const result = jitted.func();
    try out.print("{}\n", .{result});
}
