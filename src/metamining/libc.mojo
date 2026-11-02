"""Linux libc bindings for MetaMining: TCP sockets, pipes, processes,
files, directories, wall-clock time.

Pure Mojo over the platform C library (no Python anywhere). Every
function speaks only in Int/String/Bool plus the small structs below,
so callers never touch pointers or FFI types. A return of -1 (or
ok == False) signals a libc error.
"""

from std.ffi import (
    c_int,
    c_long,
    c_size_t,
    c_ssize_t,
    c_uint,
    c_ulong,
    external_call,
)
from std.memory import Pointer
from std.memory.alloc import Layout, alloc, dealloc
from std.origin import MutUntrackedOrigin

comptime AF_INET = 2
comptime SOCK_STREAM = 1
comptime SOL_SOCKET = 1
comptime SO_REUSEADDR = 2
comptime SO_RCVTIMEO = 20
comptime SO_SNDTIMEO = 21
comptime SO_ERROR = 4
comptime F_GETFL = 3
comptime F_SETFL = 4
comptime O_NONBLOCK = 2048
comptime CONNECT_TIMEOUT_MS = 10000


struct Ipv4(ImplicitlyCopyable):
    """A parsed dotted-quad address (or localhost)."""

    var ok: Bool
    var b0: UInt8
    var b1: UInt8
    var b2: UInt8
    var b3: UInt8

    def __init__(out self, ok: Bool, b0: UInt8, b1: UInt8, b2: UInt8, b3: UInt8):
        self.ok = ok
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.b3 = b3


struct PipePair(ImplicitlyCopyable):
    var ok: Bool
    var read_fd: Int
    var write_fd: Int

    def __init__(out self, ok: Bool, read_fd: Int, write_fd: Int):
        self.ok = ok
        self.read_fd = read_fd
        self.write_fd = write_fd


struct WaitResult(ImplicitlyCopyable):
    var pid: Int
    var status: Int

    def __init__(out self, pid: Int, status: Int):
        self.pid = pid
        self.status = status


def htons(port: Int) -> Int:
    return ((port & 0xFF) << 8) | ((port >> 8) & 0xFF)


def parse_ipv4(s: String) -> Ipv4:
    if s == "localhost":
        return Ipv4(True, UInt8(127), UInt8(0), UInt8(0), UInt8(1))
    var bad = Ipv4(False, UInt8(0), UInt8(0), UInt8(0), UInt8(0))
    var parts = s.split(".")
    if len(parts) != 4:
        return bad
    var vals = List[Int]()
    for i in range(4):
        var piece = String(parts[i]).strip()
        var n = 0
        var digits = 0
        for b in piece.bytes():
            var v = Int(b)
            if v < 48 or v > 57:
                return bad
            n = n * 10 + (v - 48)
            digits += 1
        if digits == 0 or digits > 3 or n > 255:
            return bad
        vals.append(n)
    return Ipv4(
        True, UInt8(vals[0]), UInt8(vals[1]), UInt8(vals[2]), UInt8(vals[3])
    )


def tcp_socket() -> Int:
    var fd = external_call["socket", c_int](c_int(AF_INET), c_int(SOCK_STREAM), c_int(0))
    return Int(fd)


def close_fd(fd: Int) -> Int:
    return Int(external_call["close", c_int](c_int(fd)))


def set_reuseaddr(fd: Int) -> Int:
    var a = alloc(Layout[c_int](count=1))
    a.unsafe_ptr().unsafe_offset(0)[] = c_int(1)
    var r = external_call["setsockopt", c_int](
        c_int(fd), c_int(SOL_SOCKET), c_int(SO_REUSEADDR), a.unsafe_ptr(), c_uint(4)
    )
    dealloc(a^)
    return Int(r)


def set_timeout(fd: Int, secs: Int) -> Int:
    # struct timeval { long tv_sec; long tv_usec; } = 16 bytes, LE.
    var a = alloc(Layout[UInt8](count=16))
    var p = a.unsafe_ptr()
    for i in range(16):
        p.unsafe_offset(i)[] = UInt8(0)
    var v = secs
    for i in range(8):
        p.unsafe_offset(i)[] = UInt8(v & 0xFF)
        v = v >> 8
    var r1 = external_call["setsockopt", c_int](
        c_int(fd), c_int(SOL_SOCKET), c_int(SO_RCVTIMEO), p, c_uint(16)
    )
    var r2 = external_call["setsockopt", c_int](
        c_int(fd), c_int(SOL_SOCKET), c_int(SO_SNDTIMEO), p, c_uint(16)
    )
    dealloc(a^)
    if Int(r1) != 0:
        return Int(r1)
    return Int(r2)


def bind_listen(host: String, port: Int) -> Int:
    """Create, bind and listen on host:port. Returns fd or -1."""
    var ip = parse_ipv4(host)
    if not ip.ok:
        return -1
    var fd = tcp_socket()
    if fd < 0:
        return -1
    _ = set_reuseaddr(fd)
    var a = alloc(Layout[UInt8](count=16))
    var p = a.unsafe_ptr()
    for i in range(16):
        p.unsafe_offset(i)[] = UInt8(0)
    p.unsafe_offset(0)[] = UInt8(2)  # AF_INET, little-endian
    var hp = htons(port)
    p.unsafe_offset(2)[] = UInt8(hp & 0xFF)
    p.unsafe_offset(3)[] = UInt8((hp >> 8) & 0xFF)
    p.unsafe_offset(4)[] = ip.b0
    p.unsafe_offset(5)[] = ip.b1
    p.unsafe_offset(6)[] = ip.b2
    p.unsafe_offset(7)[] = ip.b3
    var br = external_call["bind", c_int](c_int(fd), p, c_uint(16))
    dealloc(a^)
    if Int(br) != 0:
        _ = close_fd(fd)
        return -1
    var lr = external_call["listen", c_int](c_int(fd), c_int(32))
    if Int(lr) != 0:
        _ = close_fd(fd)
        return -1
    return fd


def socket_port(fd: Int) -> Int:
    """Return the local port of a bound socket, or -1 (getsockname)."""
    var a = alloc(Layout[UInt8](count=16))
    var p = a.unsafe_ptr()
    for i in range(16):
        p.unsafe_offset(i)[] = UInt8(0)
    var la = alloc(Layout[c_uint](count=1))
    la.unsafe_ptr().unsafe_offset(0)[] = c_uint(16)
    var r = external_call["getsockname", c_int](c_int(fd), p, la.unsafe_ptr())
    var port = -1
    if Int(r) == 0:
        var hi = Int(p.unsafe_offset(2)[])
        var lo = Int(p.unsafe_offset(3)[])
        port = (hi << 8) | lo
    dealloc(a^)
    dealloc(la^)
    return port


def accept_conn(srv: Int) -> Int:
    var a = alloc(Layout[UInt8](count=16))
    var la = alloc(Layout[c_uint](count=1))
    la.unsafe_ptr().unsafe_offset(0)[] = c_uint(16)
    var fd = external_call["accept", c_int](c_int(srv), a.unsafe_ptr(), la.unsafe_ptr())
    dealloc(a^)
    dealloc(la^)
    return Int(fd)


def set_nonblocking(fd: Int, on: Bool) -> Int:
    """Toggle O_NONBLOCK on fd. 0 on success, -1 on error."""
    var fl = external_call["fcntl", c_int](c_int(fd), c_int(F_GETFL), c_int(0))
    var fi = Int(fl)
    if fi < 0:
        return -1
    var nf = fi
    if on:
        nf = fi | O_NONBLOCK
    elif (fi & O_NONBLOCK) != 0:
        nf = fi ^ O_NONBLOCK
    if nf == fi:
        return 0
    var r = external_call["fcntl", c_int](c_int(fd), c_int(F_SETFL), c_int(nf))
    return 0 if Int(r) == 0 else -1


def sock_error(fd: Int) -> Int:
    """Pending socket error (SO_ERROR). 0 means connected, nonzero failed."""
    var va = alloc(Layout[c_int](count=1))
    var la = alloc(Layout[c_uint](count=1))
    la.unsafe_ptr().unsafe_offset(0)[] = c_uint(4)
    var r = external_call["getsockopt", c_int](
        c_int(fd),
        c_int(SOL_SOCKET),
        c_int(SO_ERROR),
        va.unsafe_ptr(),
        la.unsafe_ptr(),
    )
    var err = -1
    if Int(r) == 0:
        err = Int(va.unsafe_ptr().unsafe_offset(0)[])
    dealloc(va^)
    dealloc(la^)
    return err


def poll_writable(fd: Int, timeout_ms: Int) -> Int:
    """1 if fd is writable (connect done or failed), 0 on timeout, -1 on error."""
    var a = alloc(Layout[UInt8](count=8))
    var p = a.unsafe_ptr()
    var v = fd
    for i in range(4):
        p.unsafe_offset(i)[] = UInt8(v & 0xFF)
        v = v >> 8
    p.unsafe_offset(4)[] = UInt8(4)  # POLLOUT
    p.unsafe_offset(5)[] = UInt8(0)
    p.unsafe_offset(6)[] = UInt8(0)
    p.unsafe_offset(7)[] = UInt8(0)
    var r = external_call["poll", c_int](p, c_ulong(1), c_int(timeout_ms))
    var ri = Int(r)
    var ready = 0
    if ri > 0:
        var rev = Int(p.unsafe_offset(6)[]) | (Int(p.unsafe_offset(7)[]) << 8)
        if (rev & 4) != 0 or (rev & 24) != 0:
            ready = 1
    dealloc(a^)
    if ri < 0:
        return -1
    return ready


def tcp_connect_timeout(host: String, port: Int, timeout_ms: Int) -> Int:
    """Connect to a dotted-quad host with an explicit timeout. Returns fd or -1.

    The connect runs non-blocking under a poll timeout: SO_RCVTIMEO does
    not bound a blocking connect, so without this a blackholed route hangs
    the caller for the kernel's minutes-long TCP timeout with zero
    feedback (an expedition that never starts). A refused route still
    fails immediately via SO_ERROR.
    """
    var ip = parse_ipv4(host)
    if not ip.ok:
        return -1
    var fd = tcp_socket()
    if fd < 0:
        return -1
    _ = set_timeout(fd, 10)
    var a = alloc(Layout[UInt8](count=16))
    var p = a.unsafe_ptr()
    for i in range(16):
        p.unsafe_offset(i)[] = UInt8(0)
    p.unsafe_offset(0)[] = UInt8(2)
    var hp = htons(port)
    p.unsafe_offset(2)[] = UInt8(hp & 0xFF)
    p.unsafe_offset(3)[] = UInt8((hp >> 8) & 0xFF)
    p.unsafe_offset(4)[] = ip.b0
    p.unsafe_offset(5)[] = ip.b1
    p.unsafe_offset(6)[] = ip.b2
    p.unsafe_offset(7)[] = ip.b3
    if set_nonblocking(fd, True) != 0:
        _ = close_fd(fd)
        dealloc(a^)
        return -1
    var cr = external_call["connect", c_int](c_int(fd), p, c_uint(16))
    dealloc(a^)
    if Int(cr) != 0:
        # In progress (or already failed): wait for completion, then ask
        # the socket. No errno read needed - SO_ERROR reports both.
        var tmo = timeout_ms
        if tmo < 0:
            tmo = 0
        if poll_writable(fd, tmo) != 1 or sock_error(fd) != 0:
            _ = close_fd(fd)
            return -1
    if set_nonblocking(fd, False) != 0:
        _ = close_fd(fd)
        return -1
    return fd


def tcp_connect(host: String, port: Int) -> Int:
    """Connect to a dotted-quad host. Returns fd or -1."""
    return tcp_connect_timeout(host, port, CONNECT_TIMEOUT_MS)


def tcp_send_all(fd: Int, data: String) -> Int:
    """Send every byte (loops on partial writes). Returns count or -1."""
    var total = data.byte_length()
    if total == 0:
        return 0
    var a = alloc(Layout[UInt8](count=total))
    var p = a.unsafe_ptr()
    var i = 0
    for b in data.bytes():
        p.unsafe_offset(i)[] = UInt8(Int(b))
        i += 1
    var sent = 0
    while sent < total:
        var n = external_call["send", c_ssize_t](
            c_int(fd), p.unsafe_offset(sent), c_size_t(total - sent), c_int(0)
        )
        var ni = Int(n)
        if ni <= 0:
            dealloc(a^)
            return -1
        sent += ni
    dealloc(a^)
    return sent


def tcp_recv_some(fd: Int, cap: Int) -> String:
    """One recv() call, up to cap bytes. Empty means closed or error."""
    if cap <= 0:
        return String()
    var a = alloc(Layout[UInt8](count=cap))
    var n = external_call["recv", c_ssize_t](
        c_int(fd), a.unsafe_ptr(), c_size_t(cap), c_int(0)
    )
    var ni = Int(n)
    var out = String()
    if ni > 0:
        out = String(
            from_utf8_lossy=Span[UInt8](unsafe_ptr=a.unsafe_ptr(), length=ni)
        )
    dealloc(a^)
    return out


def poll_one(fd: Int, timeout_ms: Int) -> Int:
    """1 if fd is readable (or hung up), 0 on timeout, -1 on error."""
    var a = alloc(Layout[UInt8](count=8))
    var p = a.unsafe_ptr()
    var v = fd
    for i in range(4):
        p.unsafe_offset(i)[] = UInt8(v & 0xFF)
        v = v >> 8
    p.unsafe_offset(4)[] = UInt8(1)  # POLLIN
    p.unsafe_offset(5)[] = UInt8(0)
    p.unsafe_offset(6)[] = UInt8(0)
    p.unsafe_offset(7)[] = UInt8(0)
    var r = external_call["poll", c_int](p, c_ulong(1), c_int(timeout_ms))
    var ri = Int(r)
    var ready = 0
    if ri > 0:
        var rev = Int(p.unsafe_offset(6)[]) | (Int(p.unsafe_offset(7)[]) << 8)
        if (rev & 1) != 0 or (rev & 24) != 0:
            ready = 1
    dealloc(a^)
    if ri < 0:
        return -1
    return ready


def pipe_fds() -> PipePair:
    var a = alloc(Layout[c_int](count=2))
    var r = external_call["pipe", c_int](a.unsafe_ptr())
    var pair = PipePair(False, -1, -1)
    if Int(r) == 0:
        var p = a.unsafe_ptr()
        pair = PipePair(True, Int(p.unsafe_offset(0)[]), Int(p.unsafe_offset(1)[]))
    dealloc(a^)
    return pair


def pipe_write_all(fd: Int, data: String) -> Int:
    var total = data.byte_length()
    if total == 0:
        return 0
    var a = alloc(Layout[UInt8](count=total))
    var p = a.unsafe_ptr()
    var i = 0
    for b in data.bytes():
        p.unsafe_offset(i)[] = UInt8(Int(b))
        i += 1
    var sent = 0
    while sent < total:
        var n = external_call["write", c_ssize_t](
            c_int(fd), p.unsafe_offset(sent), c_size_t(total - sent)
        )
        var ni = Int(n)
        if ni <= 0:
            dealloc(a^)
            return -1
        sent += ni
    dealloc(a^)
    return sent


def pipe_read_some(fd: Int, cap: Int) -> String:
    if cap <= 0:
        return String()
    var a = alloc(Layout[UInt8](count=cap))
    var n = external_call["read", c_ssize_t](
        c_int(fd), a.unsafe_ptr(), c_size_t(cap)
    )
    var ni = Int(n)
    var out = String()
    if ni > 0:
        out = String(
            from_utf8_lossy=Span[UInt8](unsafe_ptr=a.unsafe_ptr(), length=ni)
        )
    dealloc(a^)
    return out


def fork_child() -> Int:
    return Int(external_call["fork", c_int]())


def child_exit(code: Int):
    _ = external_call["_exit", c_int](c_int(code))


def wait_child(pid: Int, nohang: Bool) -> WaitResult:
    var a = alloc(Layout[c_int](count=1))
    var flags = 1 if nohang else 0
    var r = external_call["waitpid", c_int](c_int(pid), a.unsafe_ptr(), c_int(flags))
    var res = WaitResult(Int(r), Int(a.unsafe_ptr().unsafe_offset(0)[]))
    dealloc(a^)
    return res


def kill_pid(pid: Int, sig: Int) -> Int:
    return Int(external_call["kill", c_int](c_int(pid), c_int(sig)))


def msleep(ms: Int):
    _ = external_call["usleep", c_int](c_uint(ms * 1000))


def mono_ms() -> Int:
    """Monotonic wall clock in ms (clock_gettime); -1 on error."""
    var a = alloc(Layout[c_long](count=2))
    var r = external_call["clock_gettime", c_int](c_int(1), a.unsafe_ptr())
    var ms = -1
    if Int(r) == 0:
        var p = a.unsafe_ptr()
        var sec = Int(p.unsafe_offset(0)[])
        var nsec = Int(p.unsafe_offset(1)[])
        ms = sec * 1000 + nsec // 1000000
    dealloc(a^)
    return ms


def ignore_sigpipe():
    # signal(SIGPIPE, SIG_IGN): dead peers surface as EPIPE, not death.
    _ = external_call["signal", c_ulong](c_int(13), c_ulong(1))


def file_write_all(path: String, data: String) -> Int:
    """Write data to path (create/truncate). Returns byte count or -1.

    Uses Mojo's builtin open(), which also creates missing parent
    directories (mkdir -p side effect).
    """
    try:
        with open(path, "w") as f:
            f.write(data)
        return data.byte_length()
    except:
        return -1


def file_append_all(path: String, data: String) -> Int:
    """Append data to path (create if missing). Returns byte count or -1.

    Uses Mojo's builtin open() in append mode, which also creates
    missing parent directories (mkdir -p side effect), like
    file_write_all.
    """
    try:
        with open(path, "a") as f:
            f.write(data)
        return data.byte_length()
    except:
        return -1


def file_read_all(path: String) -> String:
    """Read a whole file as String. Empty string on error or empty file."""
    try:
        with open(path, "r") as f:
            return f.read()
    except:
        return String()


def _read_i64(p: Pointer[UInt8, ...], off: Int) -> Int:
    var v = 0
    for i in range(8):
        v |= Int(p.unsafe_offset(off + i)[]) << (i * 8)
    return v


def dir_list(path: String) -> List[String]:
    """Entry names in path via opendir/readdir (no "." / "..").

    Order is filesystem order (unsorted). Empty list on error.
    """
    var out = List[String]()
    var n = path.byte_length()
    var a = alloc(Layout[UInt8](count=n + 1))
    var p = a.unsafe_ptr()
    var i = 0
    for b in path.bytes():
        p.unsafe_offset(i)[] = UInt8(Int(b))
        i += 1
    p.unsafe_offset(n)[] = UInt8(0)
    var d = Int(external_call["opendir", c_ulong](p))
    if d != 0:
        while True:
            var e = Int(external_call["readdir", c_ulong](c_ulong(d)))
            if e == 0:
                break
            # struct dirent: d_name starts at byte offset 19 (x86-64).
            var ep = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=e)
            var m = 0
            while m < 256:
                if Int(ep.unsafe_offset(19 + m)[]) == 0:
                    break
                m += 1
            var name = String(
                from_utf8_lossy=Span[UInt8](
                    unsafe_ptr=ep.unsafe_offset(19), length=m
                )
            )
            if name != "." and name != "..":
                out.append(name)
        _ = external_call["closedir", c_int](c_ulong(d))
    dealloc(a^)
    return out^


def file_stat(path: String) -> Tuple[Int, Int]:
    """(size bytes, mtime epoch secs) via stat; (-1, -1) on error."""
    var n = path.byte_length()
    var a = alloc(Layout[UInt8](count=n + 1))
    var p = a.unsafe_ptr()
    var i = 0
    for b in path.bytes():
        p.unsafe_offset(i)[] = UInt8(Int(b))
        i += 1
    p.unsafe_offset(n)[] = UInt8(0)
    # struct stat is 144 bytes on x86-64: st_size @48, st_mtime @88.
    var sb = alloc(Layout[UInt8](count=144))
    var sp = sb.unsafe_ptr()
    for j in range(144):
        sp.unsafe_offset(j)[] = UInt8(0)
    var r = external_call["stat", c_int](p, sp)
    var size = -1
    var mtime = -1
    if Int(r) == 0:
        size = _read_i64(sp, 48)
        mtime = _read_i64(sp, 88)
    dealloc(sb^)
    dealloc(a^)
    return (size, mtime)


def time_now() -> Int:
    """Epoch seconds (clock_gettime REALTIME); -1 on error."""
    var a = alloc(Layout[c_long](count=2))
    var p = a.unsafe_ptr()
    var r = external_call["clock_gettime", c_int](c_int(0), p)
    var sec = -1
    if Int(r) == 0:
        sec = Int(p.unsafe_offset(0)[])
    dealloc(a^)
    return sec


def _format_time(ts: Int, fmt: String) -> String:
    """Format epoch secs with a strftime pattern (local time)."""
    var out = String()
    var ta = alloc(Layout[UInt8](count=8))
    var tp = ta.unsafe_ptr()
    var v = ts
    for i in range(8):
        tp.unsafe_offset(i)[] = UInt8(v & 0xFF)
        v = v >> 8
    var tm = Int(external_call["localtime", c_ulong](tp))
    if tm != 0:
        var n = fmt.byte_length()
        var fa = alloc(Layout[UInt8](count=n + 1))
        var fp = fa.unsafe_ptr()
        var k = 0
        for b in fmt.bytes():
            fp.unsafe_offset(k)[] = UInt8(Int(b))
            k += 1
        fp.unsafe_offset(n)[] = UInt8(0)
        var ba = alloc(Layout[UInt8](count=32))
        var bp = ba.unsafe_ptr()
        for j in range(32):
            bp.unsafe_offset(j)[] = UInt8(0)
        var w = Int(
            external_call["strftime", c_size_t](
                bp, c_size_t(32), fp, c_ulong(tm)
            )
        )
        if w > 0:
            out = String(
                from_utf8_lossy=Span[UInt8](unsafe_ptr=bp, length=w)
            )
        dealloc(ba^)
        dealloc(fa^)
    dealloc(ta^)
    return out


def format_stamp(ts: Int) -> String:
    """Epoch secs -> "YYYYMMDD_HHMMSS" local time (15 chars)."""
    return _format_time(ts, "%Y%m%d_%H%M%S")


def format_mtime(ts: Int) -> String:
    """Epoch secs -> "YYYY-MM-DD HH:MM" local time (16 chars)."""
    return _format_time(ts, "%Y-%m-%d %H:%M")


def file_remove(path: String) -> Int:
    """Delete path via unlink. 0 on success, -1 on error."""
    var n = path.byte_length()
    var a = alloc(Layout[UInt8](count=n + 1))
    var p = a.unsafe_ptr()
    var i = 0
    for b in path.bytes():
        p.unsafe_offset(i)[] = UInt8(Int(b))
        i += 1
    p.unsafe_offset(n)[] = UInt8(0)
    var rc = Int(external_call["unlink", c_int](p))
    dealloc(a^)
    return rc


def dir_make(path: String) -> Int:
    """Single-level mkdir (mode 0755). 0 on success or EEXIST, else -1."""
    var n = path.byte_length()
    var a = alloc(Layout[UInt8](count=n + 1))
    var p = a.unsafe_ptr()
    var i = 0
    for b in path.bytes():
        p.unsafe_offset(i)[] = UInt8(Int(b))
        i += 1
    p.unsafe_offset(n)[] = UInt8(0)
    # mkdirat(AT_FDCWD) == mkdir; used because the "mkdir" symbol is
    # already declared with another signature via the open() builtin.
    var rc = Int(external_call["mkdirat", c_int](c_int(-100), p, c_int(493)))
    if rc != 0:
        var ep = external_call["__errno_location", Pointer[c_int, MutUntrackedOrigin]]()
        if Int(ep[]) == 17:  # EEXIST
            rc = 0
        else:
            rc = -1
    dealloc(a^)
    return rc
