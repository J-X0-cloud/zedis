//! Thin, typed wrappers over the raw Linux syscalls zedis needs.
//!
//! The standard library's higher level I/O interfaces are built around an
//! `Io` abstraction that wants to own scheduling. A single-threaded epoll
//! server wants the opposite: direct, non-blocking syscalls whose errno is
//! turned into a small Zig error set. Everything in here is deliberately
//! boring and free of policy.

const std = @import("std");
const linux = std.os.linux;

pub const fd_t = linux.fd_t;

pub const Error = error{
    WouldBlock,
    Interrupted,
    ConnectionReset,
    BrokenPipe,
    AddressInUse,
    AddressNotAvailable,
    ConnectionRefused,
    InProgress,
    FileNotFound,
    AccessDenied,
    NoSpaceLeft,
    TooManyOpenFiles,
    InvalidArgument,
    BadFileDescriptor,
    NoChildProcess,
    PathAlreadyExists,
    NameTooLong,
    Unexpected,
};

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .AGAIN => error.WouldBlock,
        .INTR => error.Interrupted,
        .CONNRESET => error.ConnectionReset,
        .PIPE => error.BrokenPipe,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .CONNREFUSED => error.ConnectionRefused,
        .INPROGRESS => error.InProgress,
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOSPC => error.NoSpaceLeft,
        .MFILE, .NFILE => error.TooManyOpenFiles,
        .INVAL => error.InvalidArgument,
        .BADF => error.BadFileDescriptor,
        .CHILD => error.NoChildProcess,
        .EXIST => error.PathAlreadyExists,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

/// Copies `path` into a NUL-terminated stack buffer for syscalls.
pub const PathZ = struct {
    buf: [4096]u8,
    len: usize,

    pub fn init(path: []const u8) Error!PathZ {
        var p: PathZ = .{ .buf = undefined, .len = path.len };
        if (path.len >= p.buf.len) return error.NameTooLong;
        @memcpy(p.buf[0..path.len], path);
        p.buf[path.len] = 0;
        return p;
    }

    pub fn ptr(self: *const PathZ) [*:0]const u8 {
        return @ptrCast(&self.buf);
    }
};

// ----------------------------------------------------------------- files --

pub const OpenMode = enum { read, append_create, write_truncate };

pub fn open(path: []const u8, mode: OpenMode) Error!fd_t {
    const p = try PathZ.init(path);
    const flags: linux.O = switch (mode) {
        .read => .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        .append_create => .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true },
        .write_truncate => .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true },
    };
    const rc = try check(linux.open(p.ptr(), flags, 0o644));
    return @intCast(rc);
}

pub fn close(fd: fd_t) void {
    _ = linux.close(fd);
}

pub fn read(fd: fd_t, buf: []u8) Error!usize {
    while (true) {
        return check(linux.read(fd, buf.ptr, buf.len)) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
    }
}

pub fn write(fd: fd_t, buf: []const u8) Error!usize {
    while (true) {
        return check(linux.write(fd, buf.ptr, buf.len)) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
    }
}

/// Writes all of `buf`, retrying on short writes. Only for blocking fds.
pub fn writeAll(fd: fd_t, buf: []const u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) {
        off += try write(fd, buf[off..]);
    }
}

pub fn fsync(fd: fd_t) Error!void {
    _ = try check(linux.fsync(fd));
}

pub fn rename(old: []const u8, new: []const u8) Error!void {
    const a = try PathZ.init(old);
    const b = try PathZ.init(new);
    _ = try check(linux.rename(a.ptr(), b.ptr()));
}

pub fn unlink(path: []const u8) Error!void {
    const p = try PathZ.init(path);
    _ = try check(linux.unlink(p.ptr()));
}

pub fn fileSize(fd: fd_t) Error!u64 {
    const end = linux.lseek(fd, 0, linux.SEEK.END);
    _ = try check(end);
    _ = try check(linux.lseek(fd, 0, linux.SEEK.SET));
    return end;
}

pub fn ftruncate(fd: fd_t, len: u64) Error!void {
    _ = try check(linux.ftruncate(fd, @intCast(len)));
}

/// Reads a whole file into memory. Returns `null` when it does not exist.
pub fn readFileAlloc(gpa: std.mem.Allocator, path: []const u8) (Error || std.mem.Allocator.Error)!?[]u8 {
    const fd = open(path, .read) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer close(fd);
    const size = try fileSize(fd);
    const buf = try gpa.alloc(u8, @intCast(size));
    errdefer gpa.free(buf);
    var off: usize = 0;
    while (off < buf.len) {
        const n = try read(fd, buf[off..]);
        if (n == 0) break;
        off += n;
    }
    return buf[0..off];
}

// ------------------------------------------------------------------ time --

/// Wall clock in milliseconds since the Unix epoch.
pub fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Wall clock in microseconds since the Unix epoch.
pub fn nowUs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1_000_000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1000);
}

/// Monotonic clock in nanoseconds, for measuring durations.
pub fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn sleepMs(ms: u64) void {
    var req: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    while (true) {
        var rem: linux.timespec = undefined;
        const rc = linux.nanosleep(&req, &rem);
        if (linux.errno(rc) == .INTR) {
            req = rem;
            continue;
        }
        return;
    }
}

/// Fills `buf` with entropy from the kernel.
pub fn getRandom(buf: []u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const rc = linux.getrandom(buf[off..].ptr, buf.len - off, 0);
        if (linux.errno(rc) != .SUCCESS) return;
        off += rc;
    }
}

// --------------------------------------------------------------- sockets --

pub const Ipv4 = struct {
    addr: [4]u8,
    port: u16,

    pub fn parse(host: []const u8, port: u16) Error!Ipv4 {
        const name = if (std.mem.eql(u8, host, "localhost")) "127.0.0.1" else host;
        var out: Ipv4 = .{ .addr = undefined, .port = port };
        var it = std.mem.splitScalar(u8, name, '.');
        var i: usize = 0;
        while (it.next()) |part| : (i += 1) {
            if (i >= 4) return error.InvalidArgument;
            out.addr[i] = std.fmt.parseInt(u8, part, 10) catch return error.InvalidArgument;
        }
        if (i != 4) return error.InvalidArgument;
        return out;
    }

    fn toSockaddr(self: Ipv4) linux.sockaddr.in {
        return .{
            .port = std.mem.nativeToBig(u16, self.port),
            .addr = @bitCast(self.addr),
        };
    }
};

pub fn setNonBlocking(fd: fd_t) Error!void {
    const flags = try check(linux.fcntl(fd, linux.F.GETFL, 0));
    const nonblock: usize = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
    _ = try check(linux.fcntl(fd, linux.F.SETFL, flags | nonblock));
}

fn setIntOpt(fd: fd_t, level: i32, opt: u32, value: c_int) Error!void {
    const bytes = std.mem.asBytes(&value);
    _ = try check(linux.setsockopt(fd, level, opt, bytes.ptr, @intCast(bytes.len)));
}

/// Creates a non-blocking listening TCP socket bound to `addr`.
/// Port 0 picks an ephemeral port; use `localPort` to discover it.
pub fn listenTcp(addr: Ipv4, backlog: u31) Error!fd_t {
    const fd: fd_t = @intCast(try check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0)));
    errdefer close(fd);
    try setIntOpt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, 1);
    var sa = addr.toSockaddr();
    _ = try check(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)));
    _ = try check(linux.listen(fd, backlog));
    return fd;
}

pub fn localPort(fd: fd_t) Error!u16 {
    var sa: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    _ = try check(linux.getsockname(fd, @ptrCast(&sa), &len));
    return std.mem.bigToNative(u16, sa.port);
}

pub const Accepted = struct {
    fd: fd_t,
    addr: Ipv4,
};

pub fn accept(listen_fd: fd_t) Error!Accepted {
    var sa: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    while (true) {
        const rc = check(linux.accept4(listen_fd, @ptrCast(&sa), &len, linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK)) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
        const fd: fd_t = @intCast(rc);
        setIntOpt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1) catch {};
        return .{ .fd = fd, .addr = .{ .addr = @bitCast(sa.addr), .port = std.mem.bigToNative(u16, sa.port) } };
    }
}

/// Opens a blocking TCP connection. Used by the client library and tests.
pub fn connectTcp(addr: Ipv4) Error!fd_t {
    const fd: fd_t = @intCast(try check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
    errdefer close(fd);
    var sa = addr.toSockaddr();
    while (true) {
        _ = check(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
        break;
    }
    setIntOpt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, 1) catch {};
    return fd;
}

/// Sends without raising SIGPIPE when the peer has gone away.
pub fn send(fd: fd_t, buf: []const u8) Error!usize {
    while (true) {
        return check(linux.sendto(fd, buf.ptr, buf.len, linux.MSG.NOSIGNAL, null, 0)) catch |err| switch (err) {
            error.Interrupted => continue,
            else => return err,
        };
    }
}

pub fn sendAll(fd: fd_t, buf: []const u8) Error!void {
    var off: usize = 0;
    while (off < buf.len) off += try send(fd, buf[off..]);
}

pub fn shutdownBoth(fd: fd_t) void {
    _ = linux.shutdown(fd, linux.SHUT.RDWR);
}

// ----------------------------------------------------------------- epoll --

pub const Epoll = struct {
    fd: fd_t,

    pub const Event = linux.epoll_event;
    pub const IN: u32 = linux.EPOLL.IN;
    pub const OUT: u32 = linux.EPOLL.OUT;
    pub const ERR: u32 = linux.EPOLL.ERR;
    pub const HUP: u32 = linux.EPOLL.HUP;
    pub const RDHUP: u32 = linux.EPOLL.RDHUP;

    pub fn init() Error!Epoll {
        const fd: fd_t = @intCast(try check(linux.epoll_create1(linux.EPOLL.CLOEXEC)));
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Epoll) void {
        close(self.fd);
    }

    pub fn add(self: *Epoll, fd: fd_t, events: u32, token: u64) Error!void {
        var ev: Event = .{ .events = events, .data = .{ .u64 = token } };
        _ = try check(linux.epoll_ctl(self.fd, linux.EPOLL.CTL_ADD, fd, &ev));
    }

    pub fn modify(self: *Epoll, fd: fd_t, events: u32, token: u64) Error!void {
        var ev: Event = .{ .events = events, .data = .{ .u64 = token } };
        _ = try check(linux.epoll_ctl(self.fd, linux.EPOLL.CTL_MOD, fd, &ev));
    }

    pub fn remove(self: *Epoll, fd: fd_t) void {
        _ = linux.epoll_ctl(self.fd, linux.EPOLL.CTL_DEL, fd, null);
    }

    /// Waits up to `timeout_ms` (-1 forever). Returns the ready events.
    pub fn wait(self: *Epoll, events: []Event, timeout_ms: i32) Error![]Event {
        const rc = check(linux.epoll_wait(self.fd, events.ptr, @intCast(events.len), timeout_ms)) catch |err| switch (err) {
            error.Interrupted => return events[0..0],
            else => return err,
        };
        return events[0..rc];
    }
};

/// A non-blocking eventfd used to wake the event loop from another thread
/// (for example a test harness asking the server to shut down).
pub const Waker = struct {
    fd: fd_t,

    pub fn init() Error!Waker {
        const flags: u32 = @as(u32, @bitCast(linux.O{ .NONBLOCK = true, .CLOEXEC = true }));
        const fd: fd_t = @intCast(try check(linux.eventfd(0, flags)));
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Waker) void {
        close(self.fd);
    }

    pub fn wake(self: Waker) void {
        const one: u64 = 1;
        _ = linux.write(self.fd, std.mem.asBytes(&one).ptr, 8);
    }

    pub fn drain(self: Waker) void {
        var v: u64 = 0;
        _ = linux.read(self.fd, std.mem.asBytes(&v).ptr, 8);
    }
};

// ------------------------------------------------------------- processes --

pub fn fork() Error!linux.pid_t {
    const rc = try check(linux.fork());
    return @intCast(rc);
}

pub fn exitImmediately(code: u8) noreturn {
    linux.exit_group(code);
}

pub const ChildStatus = union(enum) {
    running,
    exited: u8,
    signaled: u32,
};

/// Non-blocking reap of a specific child process.
pub fn pollChild(pid: linux.pid_t) Error!ChildStatus {
    var status: i32 = 0;
    const rc = try check(linux.wait4(pid, &status, linux.W.NOHANG, null));
    if (rc == 0) return .running;
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return .{ .exited = linux.W.EXITSTATUS(s) };
    return .{ .signaled = s & 0x7f };
}

pub fn killChild(pid: linux.pid_t) void {
    _ = linux.kill(pid, .KILL);
    var status: i32 = 0;
    _ = linux.wait4(pid, &status, 0, null);
}

pub fn getPid() linux.pid_t {
    return linux.getpid();
}

/// SIGPIPE is the classic footgun of socket servers; writes use
/// MSG_NOSIGNAL, but the AOF and stdout paths still benefit from this.
pub fn ignoreSigpipe() void {
    var act: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.PIPE, &act, null);
}

test "ipv4 parse" {
    const a = try Ipv4.parse("127.0.0.1", 6379);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &a.addr);
    const b = try Ipv4.parse("localhost", 1);
    try std.testing.expectEqual(@as(u8, 127), b.addr[0]);
    try std.testing.expectError(error.InvalidArgument, Ipv4.parse("1.2.3", 1));
    try std.testing.expectError(error.InvalidArgument, Ipv4.parse("1.2.3.4.5", 1));
    try std.testing.expectError(error.InvalidArgument, Ipv4.parse("256.0.0.1", 1));
}

test "listen on ephemeral port and connect" {
    const lfd = try listenTcp(try Ipv4.parse("127.0.0.1", 0), 16);
    defer close(lfd);
    const port = try localPort(lfd);
    try std.testing.expect(port != 0);
    const cfd = try connectTcp(try Ipv4.parse("127.0.0.1", port));
    defer close(cfd);
    var tries: usize = 0;
    const acc = while (tries < 100) : (tries += 1) {
        break accept(lfd) catch |err| switch (err) {
            error.WouldBlock => {
                sleepMs(1);
                continue;
            },
            else => return err,
        };
    } else return error.Unexpected;
    defer close(acc.fd);
    try sendAll(cfd, "ping");
    var buf: [8]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        got += read(acc.fd, buf[got..]) catch |err| switch (err) {
            error.WouldBlock => {
                sleepMs(1);
                continue;
            },
            else => return err,
        };
    }
    try std.testing.expectEqualStrings("ping", buf[0..4]);
}
