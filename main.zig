const std = @import("std");

const DEFAULT_BIN_PATH = "/bin/{s}";

const BuiltinFn = *const fn (allocator: std.mem.Allocator, args: [][]const u8, stdOut: *std.Io.Writer) anyerror!void;

fn helpCmd(allocator: std.mem.Allocator, args: [][]const u8, stdOut: *std.Io.Writer) anyerror!void {
    _ = allocator;
    _ = args;
    try stdOut.writeAll("Built-in command executed! Available commands: help, clear, exit\n");
}

fn clearCmd(allocator: std.mem.Allocator, args: [][]const u8, stdOut: *std.Io.Writer) anyerror!void {
    _ = allocator;
    _ = args;
    // ANSI escape codes: move cursor home, clear screen, clear scrollback
    try stdOut.writeAll("\x1b[H\x1b[2J\x1b[3J");
}

pub fn readString(allocator: std.mem.Allocator, stdIn: *std.Io.Reader) !?[]u8 {
    if (try stdIn.takeDelimiter('\n')) |line| {
        const trimmedLine = std.mem.trimEnd(u8, line, "\r");
        return try allocator.dupe(u8, trimmedLine);
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var inBuf: [1024]u8 = undefined;
    var inReader = std.Io.File.stdin().reader(io, &inBuf);

    var outBuf: [1024]u8 = undefined;
    var outWriter = std.Io.File.stdout().writer(io, &outBuf);

    const stdIn = &inReader.interface;
    const stdOut = &outWriter.interface;

    var builtins = std.StringHashMap(BuiltinFn).init(allocator);
    defer builtins.deinit();

    try builtins.put("help", helpCmd);
    try builtins.put("clear", clearCmd);

    while (true) {

		const currentDir = std.Io.Dir.cwd();
		var a_buff: [std.fs.max_path_bytes]u8 = undefined;

		if (currentDir.realPathFile(io, ".", &a_buff)) |n_len| {
			const commandInputText = try std.fmt.allocPrint(allocator, "[{s}] :)  ", .{a_buff[0..n_len]});
			try stdOut.writeAll(commandInputText);
        	try stdOut.flush();
        	allocator.free(commandInputText);
		} else |err_x| {
			std.debug.print("Error {any}\n", .{err_x});
		}
		
        if (try readString(allocator, stdIn)) |userStr| {
            defer allocator.free(userStr);

            var argIterator = std.mem.tokenizeScalar(u8, userStr, ' ');

            var args: std.ArrayList([]const u8) = .empty;
            defer args.deinit(allocator);

            while (argIterator.next()) |token| {
                try args.append(allocator, token);
            }

            if (args.items.len == 0) continue;

            const cmd = args.items[0];

            if (std.mem.eql(u8, cmd, "exit")) {
                break;
            }

            if (builtins.get(cmd)) |builtinFn| {
                builtinFn(allocator, args.items, stdOut) catch |err| {
                    try stdOut.print("Built-in error: {}\n", .{err});
                };
                try stdOut.flush();
                continue;
            }

            const childPid = std.os.linux.fork();
            const signedPid: isize = @bitCast(childPid);

            if (signedPid < 0) {
                try stdOut.print("Fork failed with OS error code: {}\n", .{signedPid});
                try stdOut.flush();
                continue;
            } else if (childPid == 0) {
                const pathSlice = std.fmt.allocPrint(allocator, DEFAULT_BIN_PATH, .{cmd}) catch std.os.linux.exit(1);
                const binPath = allocator.dupeZ(u8, pathSlice) catch std.os.linux.exit(1);

                var argvZ: std.ArrayList(?[*:0]const u8) = .empty;

                for (args.items) |arg| {
                    const argZ = allocator.dupeZ(u8, arg) catch std.os.linux.exit(1);
                    argvZ.append(allocator, argZ.ptr) catch std.os.linux.exit(1);
                }
                argvZ.append(allocator, null) catch std.os.linux.exit(1);

                const argvPtr: [*:null]const ?[*:0]const u8 = @ptrCast(argvZ.items.ptr);

                const envp = [_:null]?[*:0]const u8{};

                const execErr = std.os.linux.execve(binPath.ptr, argvPtr, &envp);

                std.debug.print("Command execution failed: {}\n", .{execErr});
                std.os.linux.exit(1);
            } else {
                const pid: i32 = @intCast(childPid);

                var status: u32 = 0;
                _ = std.os.linux.wait4(pid, &status, 0, null);
                
                std.debug.print("\n[{s}] exited with code {d}\n", .{cmd, status});
            }
        } else {
            try stdOut.writeAll("\n");
            try stdOut.flush();
            break;
        }
    }
}
