"""HTTP/1.1 messages: parse, build, and a small blocking client.

Server side parses requests incrementally; client side fetches with
Connection: close framing (content-length, chunked, or read-to-close).
"""

from metamining.json import hex_val
from metamining.libc import close_fd, tcp_connect, tcp_recv_some, tcp_send_all
from metamining.tls import tls_close, tls_connect, tls_read_some, tls_write_all


struct HttpRequest(Copyable, Movable):
    var method: String
    var target: String
    var path: String
    var query: Dict[String, String]
    var headers: Dict[String, String]
    var body: String
    var complete: Bool
    var consumed: Int

    def __init__(out self):
        self.method = String()
        self.target = String()
        self.path = String()
        self.query = Dict[String, String]()
        self.headers = Dict[String, String]()
        self.body = String()
        self.complete = False
        self.consumed = 0


struct HttpResponse(Copyable, Movable):
    var status: Int
    var headers: Dict[String, String]
    var body: String

    def __init__(out self):
        self.status = 0
        self.headers = Dict[String, String]()
        self.body = String()


struct EndpointUrl(Copyable, Movable):
    var ok: Bool
    var scheme: String
    var host: String
    var port: Int
    var base: String

    def __init__(out self, ok: Bool, scheme: String, host: String, port: Int, base: String):
        self.ok = ok
        self.scheme = scheme
        self.host = host
        self.port = port
        self.base = base


struct ClientResp(Copyable, Movable):
    var ok: Bool
    var status: Int
    var body: String
    var err: String

    def __init__(out self, ok: Bool, status: Int, body: String, err: String):
        self.ok = ok
        self.status = status
        self.body = body
        self.err = err


struct WebFile(Copyable, Movable):
    var found: Bool
    var ctype: String
    var body: String

    def __init__(out self, found: Bool, ctype: String, body: String):
        self.found = found
        self.ctype = ctype
        self.body = body


def hget(h: Dict[String, String], k: String) -> String:
    try:
        return h[k]
    except:
        return String()


def pct_decode(s: String) -> String:
    var out = List[UInt8]()
    var bytes = List[Int]()
    for b in s.bytes():
        bytes.append(Int(b))
    var i = 0
    while i < len(bytes):
        var c = bytes[i]
        if c == 37 and i + 2 < len(bytes):
            var hi = hex_val(bytes[i + 1])
            var lo = hex_val(bytes[i + 2])
            if hi >= 0 and lo >= 0:
                out.append(UInt8((hi << 4) | lo))
                i += 3
                continue
        if c == 43:
            out.append(UInt8(32))
        else:
            out.append(UInt8(c))
        i += 1
    return String(from_utf8_lossy=Span[UInt8](out))


def parse_query(q: String) -> Dict[String, String]:
    var d = Dict[String, String]()
    if q == "":
        return d.copy()
    var pairs = q.split("&")
    for i in range(len(pairs)):
        var pair = String(pairs[i])
        if pair == "":
            continue
        var eq = pair.find("=")
        if eq < 0:
            d[pct_decode(pair)] = String()
        else:
            var k = String(pair[byte=0:eq])
            var v = String(pair[byte=eq + 1 :])
            d[pct_decode(k)] = pct_decode(v)
    return d.copy()


def parse_http_request(buf: String) -> HttpRequest:
    var r = HttpRequest()
    var hend = buf.find("\r\n\r\n")
    if hend < 0:
        return r.copy()
    var head = String(buf[byte=0:hend])
    var lines = head.split("\r\n")
    if len(lines) == 0:
        return r.copy()
    var rl = String(lines[0])
    var sp1 = rl.find(" ")
    if sp1 < 0:
        return r.copy()
    var rl_rest = String(rl[byte=sp1 + 1 :])
    var sp2rel = rl_rest.find(" ")
    if sp2rel < 0:
        return r.copy()
    var sp2 = sp1 + 1 + sp2rel
    r.method = String(rl[byte=0:sp1])
    r.target = String(rl[byte=sp1 + 1 : sp2])
    for i in range(1, len(lines)):
        var ln = String(lines[i])
        var colon = ln.find(":")
        if colon > 0:
            var name = String(String(String(ln[byte=0:colon]).strip()).lower())
            var value = String(String(ln[byte=colon + 1 :]).strip())
            r.headers[name] = value
    var qm = r.target.find("?")
    if qm >= 0:
        var p = String(r.target[byte=0:qm])
        var q = String(r.target[byte=qm + 1 :])
        r.path = p
        r.query = parse_query(q)
    else:
        var t = r.target
        r.path = t
    var clen = 0
    var cl = hget(r.headers, "content-length")
    if cl != "":
        try:
            clen = Int(cl)
        except:
            clen = 0
    var need = hend + 4 + clen
    if buf.byte_length() < need:
        return r.copy()
    if clen > 0:
        r.body = String(buf[byte=hend + 4 : need])
    r.consumed = need
    r.complete = True
    return r.copy()


def parse_http_response(buf: String) -> HttpResponse:
    var r = HttpResponse()
    var hend = buf.find("\r\n\r\n")
    if hend < 0:
        return r.copy()
    var head = String(buf[byte=0:hend])
    var lines = head.split("\r\n")
    if len(lines) == 0:
        return r.copy()
    var sl = String(lines[0])
    var sp1 = sl.find(" ")
    if sp1 >= 0:
        var rest = String(String(sl[byte=sp1 + 1 :]).strip())
        var sp2 = rest.find(" ")
        var code = rest
        if sp2 >= 0:
            code = String(rest[byte=0:sp2])
        try:
            r.status = Int(code)
        except:
            r.status = 0
    for i in range(1, len(lines)):
        var ln = String(lines[i])
        var colon = ln.find(":")
        if colon > 0:
            var name = String(String(String(ln[byte=0:colon]).strip()).lower())
            var value = String(String(ln[byte=colon + 1 :]).strip())
            r.headers[name] = value
    r.body = String(buf[byte=hend + 4 :])
    return r.copy()


def dechunk(body: String) -> String:
    var out = List[UInt8]()
    var bytes = List[Int]()
    for b in body.bytes():
        bytes.append(Int(b))
    var i = 0
    while i < len(bytes):
        var line_end = -1
        var j = i
        while j + 1 < len(bytes):
            if bytes[j] == 13 and bytes[j + 1] == 10:
                line_end = j
                break
            j += 1
        if line_end < 0:
            break
        var size = 0
        var k = i
        var bad = False
        while k < line_end:
            var h = hex_val(bytes[k])
            if h < 0:
                bad = True
                break
            size = size * 16 + h
            k += 1
        if bad:
            break
        i = line_end + 2
        if size == 0:
            break
        for m in range(size):
            if i + m >= len(bytes):
                break
            out.append(UInt8(bytes[i + m]))
        i += size + 2
    return String(from_utf8_lossy=Span[UInt8](out))


def status_text(code: Int) -> String:
    if code == 200:
        return String("OK")
    if code == 202:
        return String("Accepted")
    if code == 204:
        return String("No Content")
    if code == 400:
        return String("Bad Request")
    if code == 404:
        return String("Not Found")
    if code == 405:
        return String("Method Not Allowed")
    if code == 500:
        return String("Internal Server Error")
    return String("Status")


def resp_bytes(code: Int, ctype: String, body: String) -> String:
    # no-store on everything: this is a live loopback dashboard, so any
    # heuristic caching (stale app.js, frozen /api/state polls) is pure
    # harm. Caching buys nothing at zero latency.
    return (
        String("HTTP/1.1 ")
        + String(code)
        + " "
        + status_text(code)
        + "\r\nContent-Type: "
        + ctype
        + "\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nCache-Control: no-store"
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def resp_json(body: String) -> String:
    return resp_bytes(200, "application/json", body)


def resp_bytes_h(code: Int, ctype: String, body: String, extra: String) -> String:
    """resp_bytes with one raw extra header line (no CRLF, caller-built)."""
    return (
        String("HTTP/1.1 ")
        + String(code)
        + " "
        + status_text(code)
        + "\r\nContent-Type: "
        + ctype
        + "\r\n"
        + extra
        + "\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nCache-Control: no-store"
        + "\r\nConnection: close\r\n\r\n"
        + body
    )


def resp_json_h(body: String, trig: String) -> String:
    """200 JSON plus an HX-Trigger header for htmx clients to toast on."""
    return resp_bytes_h(200, "application/json", body, "HX-Trigger: " + trig)


def sse_headers() -> String:
    return String(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
        "Cache-Control: no-cache\r\nConnection: keep-alive\r\n"
        "X-Accel-Buffering: no\r\n\r\n"
    )


def sse_event(data: String) -> String:
    var flat = data.replace("\n", "\ndata: ")
    return String("data: ") + flat + "\n\n"


def parse_endpoint_url(s: String) -> EndpointUrl:
    var bad = EndpointUrl(False, String(), String(), 0, String())
    var t = String(s.strip())
    if t == "":
        return bad.copy()
    var scheme = String("https")
    var rest = t
    var sp = t.find("://")
    if sp >= 0:
        scheme = String(String(t[byte=0:sp]).lower())
        rest = String(t[byte=sp + 3 :])
    if scheme != "http" and scheme != "https":
        return bad.copy()
    var base = String()
    var slash = rest.find("/")
    if slash >= 0:
        base = String(rest[byte=slash:])
        var bare = String(rest[byte=0:slash])
        rest = bare
    if rest == "":
        return bad.copy()
    var host = rest
    var port = 443 if scheme == "https" else 80
    var colon = rest.rfind(":")
    if colon >= 0:
        host = String(rest[byte=0:colon])
        var ps = String(rest[byte=colon + 1 :])
        try:
            port = Int(ps)
        except:
            return bad.copy()
    if host == "" or port <= 0 or port > 65535:
        return bad.copy()
    if base != "" and not base.startswith("/"):
        base = "/" + base
    return EndpointUrl(True, scheme, host, port, base).copy()


def _client_send(url: EndpointUrl, msg: String, max_bytes: Int) -> ClientResp:
    if url.scheme == "https":
        var c = tls_connect(url.host, url.port, "")
        if not c.ok:
            var e = c.err
            tls_close(c)
            return ClientResp(False, 0, String(), e).copy()
        var r = tls_write_all(c, msg)
        var out = ClientResp(False, 0, String(), String("tls write failed"))
        if r >= 0:
            var raw = String()
            while raw.byte_length() < max_bytes:
                var chunk = tls_read_some(c, 16384)
                if chunk == "":
                    break
                raw += chunk
            var resp = parse_http_response(raw)
            var body = resp.body
            if hget(resp.headers, "transfer-encoding") == "chunked":
                body = dechunk(body)
            out = ClientResp(True, resp.status, body, String())
        tls_close(c)
        return out.copy()
    var fd = tcp_connect(url.host, url.port)
    if fd < 0:
        return ClientResp(False, 0, String(), String("tcp connect failed")).copy()
    var out = ClientResp(False, 0, String(), String("http write failed"))
    if tcp_send_all(fd, msg) >= 0:
        var raw = String()
        while raw.byte_length() < max_bytes:
            var chunk = tcp_recv_some(fd, 16384)
            if chunk == "":
                break
            raw += chunk
        var resp = parse_http_response(raw)
        var body = resp.body
        if hget(resp.headers, "transfer-encoding") == "chunked":
            body = dechunk(body)
        out = ClientResp(True, resp.status, body, String())
    _ = close_fd(fd)
    return out.copy()


def http_get(url: EndpointUrl, path: String, auth: String) -> ClientResp:
    var msg = (
        String("GET ")
        + path
        + " HTTP/1.1\r\nHost: "
        + url.host
        + "\r\nConnection: close\r\nUser-Agent: metamining/0.1\r\n"
    )
    if auth != "":
        msg += "Authorization: " + auth + "\r\n"
    msg += "\r\n"
    return _client_send(url, msg, 1048576).copy()


def http_post_json(url: EndpointUrl, path: String, body: String, auth: String) -> ClientResp:
    return http_post_typed(url, path, body, auth, "application/json").copy()


def http_post_form(url: EndpointUrl, path: String, body: String) -> ClientResp:
    return http_post_typed(url, path, body, "", "application/x-www-form-urlencoded").copy()


def http_post_typed(
    url: EndpointUrl, path: String, body: String, auth: String, ctype: String
) -> ClientResp:
    var msg = (
        String("POST ")
        + path
        + " HTTP/1.1\r\nHost: "
        + url.host
        + "\r\nConnection: close\r\nUser-Agent: metamining/0.1\r\n"
        + "Content-Type: "
        + ctype
        + "\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\n"
    )
    if auth != "":
        msg += "Authorization: " + auth + "\r\n"
    msg += "\r\n" + body
    return _client_send(url, msg, 1048576).copy()


def guess_ctype(name: String) -> String:
    if name.endswith(".html"):
        return String("text/html; charset=utf-8")
    if name.endswith(".css"):
        return String("text/css; charset=utf-8")
    if name.endswith(".js"):
        return String("text/javascript; charset=utf-8")
    if name.endswith(".json"):
        return String("application/json")
    if name.endswith(".svg"):
        return String("image/svg+xml")
    return String("application/octet-stream")


def read_web_file(webdir: String, name: String) -> WebFile:
    var n = name
    if n == "" or n == "/":
        n = "index.html"
    elif n.startswith("/"):
        var rel = String(n[byte=1:])
        n = rel
    if n.find("..") >= 0 or n.startswith("/") or n == "":
        return WebFile(False, String(), String()).copy()
    try:
        var f = open(webdir + "/" + n, "r")
        var body = f.read()
        f.close()
        return WebFile(True, guess_ctype(n), body).copy()
    except:
        return WebFile(False, String(), String()).copy()
