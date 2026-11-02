"""TLS 1.3 client over the system OpenSSL (libssl.so.3), pure Mojo FFI.

No Python: Mojo code calls libssl the way it calls libc. Peer
certificates are always verified (chain + hostname). DNS names resolve
via getaddrinfo, or via an HTTP CONNECT tunnel when HTTPS_PROXY is set.

Link with: -Xlinker /lib/x86_64-linux-gnu/libssl.so.3
           -Xlinker /lib/x86_64-linux-gnu/libcrypto.so.3
"""

from std.ffi import c_int, c_long, c_size_t, c_uint, c_ulong, external_call
from std.memory import Pointer
from std.memory.alloc import Layout, alloc, dealloc
from std.origin import MutUntrackedOrigin
from std.os.env import getenv

from metamining.libc import (
    Ipv4,
    close_fd,
    parse_ipv4,
    set_timeout,
    tcp_connect,
    tcp_recv_some,
    tcp_send_all,
)


struct ProxyCfg(ImplicitlyCopyable):
    var ok: Bool
    var host: String
    var port: Int
    var user: String
    var pw: String

    def __init__(out self, ok: Bool, host: String, port: Int, user: String, pw: String):
        self.ok = ok
        self.host = host
        self.port = port
        self.user = user
        self.pw = pw


struct TlsConn(Copyable, Movable):
    var ok: Bool
    var err: String
    var fd: Int
    var ssl: Pointer[UInt8, MutUntrackedOrigin]
    var ctx: Pointer[UInt8, MutUntrackedOrigin]
    var verify: Int

    def __init__(
        out self,
        ok: Bool,
        err: String,
        fd: Int,
        ssl: Pointer[UInt8, MutUntrackedOrigin],
        ctx: Pointer[UInt8, MutUntrackedOrigin],
        verify: Int,
    ):
        self.ok = ok
        self.err = err
        self.fd = fd
        self.ssl = ssl
        self.ctx = ctx
        self.verify = verify


def errno_now() -> Int:
    var p = external_call["__errno_location", Pointer[c_int, MutUntrackedOrigin]]()
    return Int(p[])


def _read_u64(p: Pointer[UInt8, ...], off: Int) -> Int:
    var v = 0
    for i in range(8):
        v |= Int(p.unsafe_offset(off + i)[]) << (i * 8)
    return v


def getaddrinfo_ipv4(node: String, service: String) -> Ipv4:
    """Resolve a DNS name to IPv4 via libc getaddrinfo (AF_INET)."""
    var bad = Ipv4(False, UInt8(0), UInt8(0), UInt8(0), UInt8(0))
    var nb = alloc(Layout[UInt8](count=node.byte_length() + 1))
    var sb = alloc(Layout[UInt8](count=service.byte_length() + 1))
    var hb = alloc(Layout[UInt8](count=48))
    var rb = alloc(Layout[UInt8](count=8))
    var nbp = nb.unsafe_ptr()
    var _ni = 0
    for b in node.bytes():
        nbp.unsafe_offset(_ni)[] = UInt8(Int(b))
        _ni += 1
    nbp.unsafe_offset(_ni)[] = UInt8(0)
    var sbp = sb.unsafe_ptr()
    var _si = 0
    for b in service.bytes():
        sbp.unsafe_offset(_si)[] = UInt8(Int(b))
        _si += 1
    sbp.unsafe_offset(_si)[] = UInt8(0)
    var hp = hb.unsafe_ptr()
    for i in range(48):
        hp.unsafe_offset(i)[] = UInt8(0)
    hp.unsafe_offset(4)[] = UInt8(2)  # ai_family = AF_INET
    var rp = rb.unsafe_ptr()
    for i in range(8):
        rp.unsafe_offset(i)[] = UInt8(0)
    var r = external_call["getaddrinfo", c_int](
        nb.unsafe_ptr(), sb.unsafe_ptr(), hp, rp
    )
    var out = bad
    if Int(r) == 0:
        var res_addr = _read_u64(rp, 0)
        if res_addr != 0:
            var pres = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=res_addr)
            var sa_addr = _read_u64(pres, 24)  # ai_addr
            var sa_len = Int(pres.unsafe_offset(16)[]) | (
                Int(pres.unsafe_offset(17)[]) << 8
            )
            if sa_addr != 0 and sa_len >= 16:
                var psa = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=sa_addr)
                var fam = Int(psa.unsafe_offset(0)[]) | (
                    Int(psa.unsafe_offset(1)[]) << 8
                )
                if fam == 2:
                    out = Ipv4(
                        True,
                        psa.unsafe_offset(4)[],
                        psa.unsafe_offset(5)[],
                        psa.unsafe_offset(6)[],
                        psa.unsafe_offset(7)[],
                    )
            _ = external_call["freeaddrinfo", c_int](pres)
    dealloc(nb^)
    dealloc(sb^)
    dealloc(hb^)
    dealloc(rb^)
    return out


def parse_proxy_url(url: String) -> ProxyCfg:
    var bad = ProxyCfg(False, String(), 0, String(), String())
    var s = url.strip()
    if s == "":
        return bad
    var scheme = s.find("://")
    if scheme < 0:
        return bad
    var rest = String(s[byte=scheme + 3 :])
    var user = String()
    var pw = String()
    var at = rest.find("@")
    if at >= 0:
        var auth = String(rest[byte=0:at])
        var tail = String(rest[byte=at + 1 :])
        rest = tail
        var colon = auth.find(":")
        if colon >= 0:
            user = String(auth[byte=0:colon])
            pw = String(auth[byte=colon + 1 :])
        else:
            user = auth
    var hp = rest.find(":")
    if hp < 0:
        return bad
    var host = String(rest[byte=0:hp])
    var port_s = String(rest[byte=hp + 1 :])
    var slash = port_s.find("/")
    if slash >= 0:
        var bare = String(port_s[byte=0:slash])
        port_s = bare
    var port: Int
    try:
        port = Int(port_s)
    except:
        return bad
    if port <= 0 or port > 65535 or host == "":
        return bad
    return ProxyCfg(True, host, port, user, pw)


def proxy_from_env() -> ProxyCfg:
    var u = getenv("HTTPS_PROXY", "")
    if u == "":
        u = getenv("https_proxy", "")
    if u == "":
        return ProxyCfg(False, String(), 0, String(), String())
    return parse_proxy_url(u)


def _b64(s: String) -> String:
    var alpha = String(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    )
    var data = List[Int]()
    for b in s.bytes():
        data.append(Int(b))
    var out = String()
    var i = 0
    while i < len(data):
        var n = len(data) - i
        if n > 3:
            n = 3
        var v = 0
        for j in range(n):
            v |= data[i + j] << (16 - j * 8)
        out += alpha[byte=(v >> 18) & 63]
        out += alpha[byte=(v >> 12) & 63]
        if n > 1:
            out += alpha[byte=(v >> 6) & 63]
        else:
            out += "="
        if n > 2:
            out += alpha[byte=v & 63]
        else:
            out += "="
        i += 3
    return out


def connect_direct(host: String, port: Int) -> Int:
    """TCP connect to a literal IP or a DNS name (getaddrinfo)."""
    var ip = parse_ipv4(host)
    if ip.ok:
        return tcp_connect(host, port)
    var r = getaddrinfo_ipv4(host, String(port))
    if not r.ok:
        return -1
    var dotted = (
        String(Int(r.b0))
        + "."
        + String(Int(r.b1))
        + "."
        + String(Int(r.b2))
        + "."
        + String(Int(r.b3))
    )
    return tcp_connect(dotted, port)


def connect_via_proxy(proxy: ProxyCfg, host: String, port: Int) -> Int:
    """HTTP CONNECT tunnel through proxy. Returns the socket or -1."""
    var fd = connect_direct(proxy.host, proxy.port)
    if fd < 0:
        return -1
    var req = (
        String("CONNECT ")
        + host
        + ":"
        + String(port)
        + " HTTP/1.1\r\nHost: "
        + host
        + ":"
        + String(port)
        + "\r\n"
    )
    if proxy.user != "":
        req += "Proxy-Authorization: Basic " + _b64(proxy.user + ":" + proxy.pw) + "\r\n"
    req += "Proxy-Connection: Keep-Alive\r\n\r\n"
    if tcp_send_all(fd, req) < 0:
        _ = close_fd(fd)
        return -1
    var resp = String()
    for _ in range(40):
        resp += tcp_recv_some(fd, 1024)
        if resp.find("\r\n\r\n") >= 0:
            break
        if resp.byte_length() > 8192:
            break
    _ = set_timeout(fd, 30)
    if resp.find(" 200") < 0:
        _ = close_fd(fd)
        return -1
    return fd


def tls_connect(host: String, port: Int, sni_override: String) -> TlsConn:
    """TLS client handshake with full chain+hostname verification.

    Ownership is uniform: the returned conn always owns live SSL objects,
    so the caller must call tls_close() even when ok == False.
    """
    var meth = external_call["TLS_client_method", Pointer[UInt8, MutUntrackedOrigin]]()
    var ctx = external_call["SSL_CTX_new", Pointer[UInt8, MutUntrackedOrigin]](meth)
    _ = external_call["SSL_CTX_set_default_verify_paths", c_int](ctx)
    # SSL_VERIFY_PEER=1, NULL callback passed as a zero address.
    _ = external_call["SSL_CTX_set_verify", c_int](ctx, c_int(1), c_ulong(0))
    var ssl = external_call["SSL_new", Pointer[UInt8, MutUntrackedOrigin]](ctx)
    var fd: Int
    var ip = parse_ipv4(host)
    if ip.ok:
        fd = tcp_connect(host, port)
    else:
        var proxy = proxy_from_env()
        if proxy.ok:
            fd = connect_via_proxy(proxy, host, port)
        else:
            fd = connect_direct(host, port)
    if fd < 0:
        return TlsConn(False, String("tcp connect failed"), -1, ssl, ctx, -1)
    _ = external_call["SSL_set_fd", c_int](ssl, c_int(fd))
    var sni = host if sni_override == "" else sni_override
    var use_name = not parse_ipv4(sni).ok
    if use_name:
        var nb = alloc(Layout[UInt8](count=sni.byte_length() + 1))
        var nbp = nb.unsafe_ptr()
        var _ni = 0
        for b in sni.bytes():
            nbp.unsafe_offset(_ni)[] = UInt8(Int(b))
            _ni += 1
        nbp.unsafe_offset(_ni)[] = UInt8(0)
        # SSL_set_tlsext_host_name() is a macro for this SSL_ctrl call.
        _ = external_call["SSL_ctrl", c_long](ssl, c_int(55), c_long(0), nbp)
        _ = external_call["SSL_set1_host", c_int](ssl, nbp)
        dealloc(nb^)
    var ok = False
    var verr = -1
    for _ in range(100):
        var r = external_call["SSL_connect", c_int](ssl)
        if Int(r) == 1:
            ok = True
            break
        var e = external_call["SSL_get_error", c_int](ssl, r)
        if Int(e) != 2 and Int(e) != 3:
            break
    if ok:
        verr = Int(external_call["SSL_get_verify_result", c_long](ssl))
        if verr != 0:
            ok = False
    if not ok:
        return TlsConn(False, String("tls handshake/verify failed"), fd, ssl, ctx, verr)
    return TlsConn(True, String(), fd, ssl, ctx, 0)


def tls_write_all(conn: TlsConn, data: String) -> Int:
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
    var fails = 0
    while sent < total:
        var n = external_call["SSL_write", c_int](
            conn.ssl, p.unsafe_offset(sent), c_int(total - sent)
        )
        var ni = Int(n)
        if ni > 0:
            sent += ni
        else:
            var e = external_call["SSL_get_error", c_int](conn.ssl, n)
            if Int(e) != 2 and Int(e) != 3:
                break
            fails += 1
            if fails > 200:
                break
    dealloc(a^)
    if sent < total:
        return -1
    return sent


def tls_read_some(conn: TlsConn, cap: Int) -> String:
    if cap <= 0:
        return String()
    var a = alloc(Layout[UInt8](count=cap))
    var out = String()
    for _ in range(200):
        var n = external_call["SSL_read", c_int](
            conn.ssl, a.unsafe_ptr(), c_int(cap)
        )
        var ni = Int(n)
        if ni > 0:
            out = String(
                from_utf8_lossy=Span[UInt8](unsafe_ptr=a.unsafe_ptr(), length=ni)
            )
            break
        var e = external_call["SSL_get_error", c_int](conn.ssl, n)
        if Int(e) != 2 and Int(e) != 3:
            break
    dealloc(a^)
    return out


def tls_close(conn: TlsConn):
    # void-returning calls read back a dummy int; harmless by construction.
    _ = external_call["SSL_shutdown", c_int](conn.ssl)
    _ = external_call["SSL_free", c_int](conn.ssl)
    _ = external_call["SSL_CTX_free", c_int](conn.ctx)
    if conn.fd >= 0:
        _ = close_fd(conn.fd)
