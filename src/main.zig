const std = @import("std");
const x86 = @import("x86");

const Token = union(enum) {
    op: u8,
    int: i64,
};

const TokenIterator = struct {
    toks: std.mem.TokenIterator,

    pub fn init(expr: []const u8) TokenIterator {
        return .{ .toks = std.mem.tokenize(expr, " \t\n") };
    }

    pub fn next(self: *TokenIterator) !?Token {
        if (self.toks.next()) |tok| {
            if (tok.len == 1 and std.mem.indexOf(u8, "+-*/", tok) != null) {
                return Token{ .op = tok[0] };
            } else {
                const i = try std.fmt.parseInt(i64, tok, 0);
                return Token{ .int = i };
            }
        } else {
            return null;
        }
    }
};

fn Compiler(comptime Writer: type) type {
    return struct {
        w: Writer,
        m: x86.Machine,
        stackSize: u32 = 0,

        const Self = @This();

        // Create a new compiler that will output machine code to the provided writer
        pub fn init(w: Writer) !Self {
            const self = Self{
                .w = w,
                .m = x86.Machine.init(.x64),
            };
            try self.begin();
            return self;
        }

        const rax = x86.Operand.register(.RAX);
        const rdi = x86.Operand.register(.RDI);
        const rbp = x86.Operand.register(.RBP);
        const rsp = x86.Operand.register(.RSP);

        // Emit a single instruction
        fn emit(self: Self, mnem: x86.Mnemonic, operands: anytype) !void {
            var ops = [5]?*const x86.Operand{ null, null, null, null, null };
            for (@as([operands.len]x86.Operand, operands)) |*op, i| {
                ops[i] = op;
            }
            const insn = try self.m.build(null, mnem, ops[0], ops[1], ops[2], ops[3], ops[4]);
            try self.w.writeAll(insn.asSlice());
        }

        // Emit the function prelude instructions
        fn begin(self: Self) !void {
            try self.emit(.PUSH, .{rbp});
            try self.emit(.MOV, .{ rbp, rsp });
        }

        // Emit the function teardown and finish the compilation
        pub fn finish(self: Self) !void {
            if (self.stackSize < 1) {
                return error.StackUnderflow;
            } else if (self.stackSize > 1) {
                return error.UnusedOperands;
            }

            try self.emit(.POP, .{rax});
            try self.emit(.LEAVE, .{});
            try self.emit(.RET, .{});
        }

        // Emit the instructions for a given token
        pub fn compile(self: *Self, tok: Token) !void {
            switch (tok) {
                .int => |x| {
                    const val = x86.Operand.immediateSigned64(x);
                    try self.emit(.MOV, .{ rax, val });
                    try self.emit(.PUSH, .{rax});
                    self.stackSize += 1;
                },

                .op => |operator| {
                    try self.emit(.POP, .{rdi});
                    try self.emit(.POP, .{rax});

                    switch (operator) {
                        '+' => try self.emit(.ADD, .{ rax, rdi }),
                        '-' => try self.emit(.SUB, .{ rax, rdi }),
                        '*' => try self.emit(.IMUL, .{ rax, rdi }),

                        '/' => {
                            try self.emit(.CDQ, .{});
                            try self.emit(.IDIV, .{rdi});
                        },

                        else => return error.InvalidOperator,
                    }

                    try self.emit(.PUSH, .{rax});

                    if (self.stackSize < 2) {
                        return error.StackUnderflow;
                    }
                    self.stackSize -= 1;
                },
            }
        }
    };
}

fn compile(w: anytype, toks: *TokenIterator) !void {
    var compiler = try Compiler(@TypeOf(w)).init(w);
    while (try toks.next()) |tok| {
        try compiler.compile(tok);
    }
    try compiler.finish();
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

fn jit(toks: *TokenIterator) !JitResult {
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

fn printEval(expr: []const u8) !void {
    var toks = TokenIterator.init(expr);
    const jitted = try jit(&toks);
    defer jitted.deinit();

    const out = std.io.getStdOut().writer();
    try out.print("{}\n", .{jitted.func()});
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    if (args.nextPosix()) |arg| {
        try printEval(arg);
    } else {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = &gpa.allocator;

        var buf = std.ArrayList(u8).init(allocator);
        const in = std.io.getStdIn().reader();
        while (true) {
            in.readUntilDelimiterArrayList(&buf, '\n', 1 << 20) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            printEval(buf.items) catch |err| {
                try std.io.getStdErr().writer().print("{}\n", .{err});
            };
        }
    }
}
