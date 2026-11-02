"""Minimal JSON over an arena Doc: parse + render, pure Mojo.

Nodes live in flat lists (Doc.nodes/keys/vals) and are addressed by
index, which keeps JVal a small copyable handle. Covers worker lines,
OpenAI-style endpoint responses and dashboard state.
"""

from std.math import isinf, isnan

comptime J_NULL = 0
comptime J_BOOL = 1
comptime J_NUM = 2
comptime J_STR = 3
comptime J_ARR = 4
comptime J_OBJ = 5


struct JVal(ImplicitlyCopyable):
    var kind: Int
    var b: Bool
    var f: Float64
    var s: String
    var start: Int
    var count: Int

    def __init__(out self, kind: Int):
        self.kind = kind
        self.b = False
        self.f = 0.0
        self.s = String()
        self.start = 0
        self.count = 0


struct Doc(Copyable, Movable):
    var nodes: List[JVal]
    var keys: List[String]
    var vals: List[Int]

    def __init__(out self):
        self.nodes = List[JVal]()
        self.keys = List[String]()
        self.vals = List[Int]()


def doc_root(doc: Doc) -> Int:
    return len(doc.nodes) - 1


def doc_kind(doc: Doc, idx: Int) -> Int:
    if idx < 0 or idx >= len(doc.nodes):
        return J_NULL
    return doc.nodes[idx].kind


def doc_str(doc: Doc, idx: Int) -> String:
    if doc_kind(doc, idx) != J_STR:
        return String()
    return doc.nodes[idx].s


def doc_num(doc: Doc, idx: Int) -> Float64:
    if doc_kind(doc, idx) != J_NUM:
        return 0.0
    return doc.nodes[idx].f


def doc_bool(doc: Doc, idx: Int) -> Bool:
    if doc_kind(doc, idx) != J_BOOL:
        return False
    return doc.nodes[idx].b


def doc_len(doc: Doc, idx: Int) -> Int:
    if doc_kind(doc, idx) != J_ARR:
        return 0
    return doc.nodes[idx].count


def doc_at(doc: Doc, idx: Int, i: Int) -> Int:
    if doc_kind(doc, idx) != J_ARR:
        return -1
    var n = doc.nodes[idx]
    if i < 0 or i >= n.count:
        return -1
    return doc.vals[n.start + i]


def doc_find(doc: Doc, idx: Int, key: String) -> Int:
    if doc_kind(doc, idx) != J_OBJ:
        return -1
    var n = doc.nodes[idx]
    for i in range(n.count):
        if doc.keys[n.start + i] == key:
            return doc.vals[n.start + i]
    return -1


def doc_ostr(doc: Doc, idx: Int, key: String) -> String:
    return doc_str(doc, doc_find(doc, idx, key))


def doc_onum(doc: Doc, idx: Int, key: String) -> Float64:
    return doc_num(doc, doc_find(doc, idx, key))


def doc_obool(doc: Doc, idx: Int, key: String) -> Bool:
    return doc_bool(doc, doc_find(doc, idx, key))


def _hex_byte(d: Int) -> UInt8:
    if d < 10:
        return UInt8(48 + d)
    return UInt8(87 + d)


def j_escape(s: String) -> String:
    var out = List[UInt8]()
    for b in s.bytes():
        var v = Int(b)
        if v == 34:
            out.append(UInt8(92))
            out.append(UInt8(34))
        elif v == 92:
            out.append(UInt8(92))
            out.append(UInt8(92))
        elif v == 10:
            out.append(UInt8(92))
            out.append(UInt8(110))
        elif v == 13:
            out.append(UInt8(92))
            out.append(UInt8(114))
        elif v == 9:
            out.append(UInt8(92))
            out.append(UInt8(116))
        elif v == 8:
            out.append(UInt8(92))
            out.append(UInt8(98))
        elif v == 12:
            out.append(UInt8(92))
            out.append(UInt8(102))
        elif v < 32:
            out.append(UInt8(92))
            out.append(UInt8(117))
            out.append(UInt8(48))
            out.append(UInt8(48))
            out.append(_hex_byte((v >> 4) & 15))
            out.append(_hex_byte(v & 15))
        else:
            out.append(UInt8(v))
    return String(from_utf8_lossy=Span[UInt8](out))


def j_render_num(f: Float64) -> String:
    if isinf(f) or isnan(f):
        return String("0")
    if f < 1e15 and f > -1e15:
        var n = Int(f)
        if Float64(n) == f:
            return String(n)
    return String(f)


def j_render_at(doc: Doc, idx: Int) -> String:
    var k = doc_kind(doc, idx)
    if k == J_BOOL:
        return String("true") if doc_bool(doc, idx) else String("false")
    if k == J_NUM:
        return j_render_num(doc_num(doc, idx))
    if k == J_STR:
        return String("\"") + j_escape(doc_str(doc, idx)) + String("\"")
    if k == J_ARR:
        var n = doc.nodes[idx]
        var out = String("[")
        for i in range(n.count):
            if i > 0:
                out += ","
            out += j_render_at(doc, doc.vals[n.start + i])
        out += "]"
        return out
    if k == J_OBJ:
        var n = doc.nodes[idx]
        var out = String("{")
        for i in range(n.count):
            if i > 0:
                out += ","
            out += String("\"") + j_escape(doc.keys[n.start + i]) + String("\":")
            out += j_render_at(doc, doc.vals[n.start + i])
        out += "}"
        return out
    return String("null")


def doc_render(doc: Doc) -> String:
    return j_render_at(doc, doc_root(doc))


def hex_val(c: Int) -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 65 and c <= 70:
        return c - 55
    if c >= 97 and c <= 102:
        return c - 87
    return -1


def _push_utf8(mut buf: List[UInt8], cp: Int):
    var c = cp
    if c < 0 or (c >= 55296 and c <= 57343) or c > 1114111:
        c = 65533
    if c < 128:
        buf.append(UInt8(c))
    elif c < 2048:
        buf.append(UInt8(192 | (c >> 6)))
        buf.append(UInt8(128 | (c & 63)))
    elif c < 65536:
        buf.append(UInt8(224 | (c >> 12)))
        buf.append(UInt8(128 | ((c >> 6) & 63)))
        buf.append(UInt8(128 | (c & 63)))
    else:
        buf.append(UInt8(240 | (c >> 18)))
        buf.append(UInt8(128 | ((c >> 12) & 63)))
        buf.append(UInt8(128 | ((c >> 6) & 63)))
        buf.append(UInt8(128 | (c & 63)))


struct JParser(Movable):
    var buf: List[UInt8]
    var pos: Int
    var doc: Doc

    def __init__(out self, data: String):
        self.buf = List[UInt8]()
        self.pos = 0
        self.doc = Doc()
        for b in data.bytes():
            self.buf.append(UInt8(Int(b)))

    def eof(self) -> Bool:
        return self.pos >= len(self.buf)

    def peek(self) -> Int:
        if self.eof():
            return -1
        return Int(self.buf[self.pos])

    def skip_ws(mut self):
        while not self.eof():
            var c = self.peek()
            if c == 32 or c == 9 or c == 10 or c == 13:
                self.pos += 1
            else:
                break

    def expect(mut self, word: String) raises:
        for b in word.bytes():
            if self.eof() or self.peek() != Int(b):
                raise Error(String("bad json literal, wanted ") + word)
            self.pos += 1

    def push_scalar(mut self, kind: Int) -> Int:
        self.doc.nodes.append(JVal(kind))
        return len(self.doc.nodes) - 1

    def parse_num(mut self) raises -> Int:
        var neg = False
        if self.peek() == 45:
            neg = True
            self.pos += 1
        # Integer mantissa + single scaling: one rounding, not one per digit.
        var mant = 0.0
        var digits = 0
        while not self.eof():
            var c = self.peek()
            if c < 48 or c > 57:
                break
            mant = mant * 10.0 + Float64(c - 48)
            digits += 1
            self.pos += 1
        if digits == 0:
            raise Error("bad json number")
        var frac = 0
        if not self.eof() and self.peek() == 46:
            self.pos += 1
            var fdigits = 0
            while not self.eof():
                var c = self.peek()
                if c < 48 or c > 57:
                    break
                mant = mant * 10.0 + Float64(c - 48)
                fdigits += 1
                self.pos += 1
            if fdigits == 0:
                raise Error("bad json fraction")
            frac = fdigits
        var exp = 0
        if not self.eof() and (self.peek() == 101 or self.peek() == 69):
            self.pos += 1
            var eneg = False
            if not self.eof() and self.peek() == 43:
                self.pos += 1
            elif not self.eof() and self.peek() == 45:
                eneg = True
                self.pos += 1
            var edigits = 0
            while not self.eof():
                var c = self.peek()
                if c < 48 or c > 57:
                    break
                # Clamp accumulation: past 6 digits the value is already
                # far outside Float64 range; keep consuming the token.
                if edigits < 6:
                    exp = exp * 10 + (c - 48)
                edigits += 1
                self.pos += 1
            if edigits == 0:
                raise Error("bad json exponent")
            if eneg:
                exp = -exp
        # Overflowed mantissa: return signed inf, never scale inf (inf/inf is NaN).
        if isinf(mant):
            var infv = mant
            if neg:
                infv = -infv
            var iidx = self.push_scalar(J_NUM)
            var inode = self.doc.nodes[iidx]
            inode.f = infv
            self.doc.nodes[iidx] = inode
            return iidx
        var total = exp - frac
        # Beyond Float64 range the result is inf/0 anyway; bound the loops.
        if total > 324:
            total = 324
        elif total < -324:
            total = -324
        var iv = mant
        if total > 0:
            var mult = 1.0
            for _ in range(total):
                mult *= 10.0
            iv *= mult
        elif total < 0:
            var div = 1.0
            for _ in range(-total):
                div *= 10.0
            iv /= div
        if neg:
            iv = -iv
        var idx = self.push_scalar(J_NUM)
        var n = self.doc.nodes[idx]
        n.f = iv
        self.doc.nodes[idx] = n
        return idx

    def parse_hex4(mut self) raises -> Int:
        var v = 0
        for _ in range(4):
            if self.eof():
                raise Error("short unicode escape")
            var h = hex_val(self.peek())
            if h < 0:
                raise Error("bad unicode escape")
            v = v * 16 + h
            self.pos += 1
        return v

    def parse_surrogate_tail(mut self, hi: Int, mut buf: List[UInt8]) raises:
        # self.pos is right after the high surrogate's 4 hex digits.
        if self.eof() or self.peek() != 92:
            _push_utf8(buf, hi)
            return
        self.pos += 1
        if self.eof() or self.peek() != 117:
            _push_utf8(buf, hi)
            buf.append(UInt8(92))
            return
        self.pos += 1
        var lo = self.parse_hex4()
        if lo >= 56320 and lo <= 57343:
            _push_utf8(buf, 65536 + ((hi - 55296) << 10) + (lo - 56320))
        else:
            _push_utf8(buf, hi)
            _push_utf8(buf, lo)

    def parse_str_raw(mut self) raises -> String:
        self.pos += 1  # opening quote
        var buf = List[UInt8]()
        while True:
            if self.eof():
                raise Error("unterminated string")
            var c = self.peek()
            self.pos += 1
            if c == 34:
                break
            if c == 92:
                if self.eof():
                    raise Error("short escape")
                var e = self.peek()
                self.pos += 1
                if e == 34:
                    buf.append(UInt8(34))
                elif e == 92:
                    buf.append(UInt8(92))
                elif e == 47:
                    buf.append(UInt8(47))
                elif e == 98:
                    buf.append(UInt8(8))
                elif e == 102:
                    buf.append(UInt8(12))
                elif e == 110:
                    buf.append(UInt8(10))
                elif e == 114:
                    buf.append(UInt8(13))
                elif e == 116:
                    buf.append(UInt8(9))
                elif e == 117:
                    var cp = self.parse_hex4()
                    if cp >= 55296 and cp <= 56319:
                        self.parse_surrogate_tail(cp, buf)
                    else:
                        _push_utf8(buf, cp)
                else:
                    raise Error("bad escape")
            elif c < 32:
                raise Error("raw control in string")
            else:
                buf.append(UInt8(c))
        return String(from_utf8_lossy=Span[UInt8](buf))

    def parse_str(mut self) raises -> Int:
        var s = self.parse_str_raw()
        var idx = self.push_scalar(J_STR)
        var n = self.doc.nodes[idx]
        n.s = s
        self.doc.nodes[idx] = n
        return idx

    def parse_arr(mut self, depth: Int) raises -> Int:
        if depth > 256:
            raise Error("json nesting too deep")
        self.pos += 1  # [
        var vs = List[Int]()
        self.skip_ws()
        if self.eof():
            raise Error("unterminated array")
        if self.peek() != 93:
            while True:
                self.skip_ws()
                vs.append(self.parse_value(depth + 1))
                self.skip_ws()
                if self.eof():
                    raise Error("unterminated array")
                var c = self.peek()
                self.pos += 1
                if c == 93:
                    break
                if c != 44:
                    raise Error("wanted , or ]")
        else:
            self.pos += 1
        var start = len(self.doc.vals)
        for i in range(len(vs)):
            # Keep keys/vals aligned: arrays carry placeholder keys.
            self.doc.keys.append(String())
            self.doc.vals.append(vs[i])
        var node = JVal(J_ARR)
        node.start = start
        node.count = len(vs)
        self.doc.nodes.append(node)
        return len(self.doc.nodes) - 1

    def parse_obj(mut self, depth: Int) raises -> Int:
        if depth > 256:
            raise Error("json nesting too deep")
        self.pos += 1  # {
        var ks = List[String]()
        var vs = List[Int]()
        self.skip_ws()
        if self.eof():
            raise Error("unterminated object")
        if self.peek() != 125:
            while True:
                self.skip_ws()
                if self.eof() or self.peek() != 34:
                    raise Error("wanted string key")
                ks.append(self.parse_str_raw())
                self.skip_ws()
                if self.eof() or self.peek() != 58:
                    raise Error("wanted :")
                self.pos += 1
                self.skip_ws()
                vs.append(self.parse_value(depth + 1))
                self.skip_ws()
                if self.eof():
                    raise Error("unterminated object")
                var c = self.peek()
                self.pos += 1
                if c == 125:
                    break
                if c != 44:
                    raise Error("wanted , or }")
        else:
            self.pos += 1
        var start = len(self.doc.vals)
        for i in range(len(vs)):
            self.doc.keys.append(ks[i])
            self.doc.vals.append(vs[i])
        var node = JVal(J_OBJ)
        node.start = start
        node.count = len(vs)
        self.doc.nodes.append(node)
        return len(self.doc.nodes) - 1

    def parse_value(mut self, depth: Int) raises -> Int:
        self.skip_ws()
        if self.eof():
            raise Error("empty value")
        var c = self.peek()
        if c == 123:
            return self.parse_obj(depth)
        if c == 91:
            return self.parse_arr(depth)
        if c == 34:
            return self.parse_str()
        if c == 116:
            self.expect("true")
            var ti = self.push_scalar(J_BOOL)
            var tn = self.doc.nodes[ti]
            tn.b = True
            self.doc.nodes[ti] = tn
            return ti
        if c == 102:
            self.expect("false")
            return self.push_scalar(J_BOOL)
        if c == 110:
            self.expect("null")
            return self.push_scalar(J_NULL)
        if c == 45 or (c >= 48 and c <= 57):
            return self.parse_num()
        raise Error("bad value")


def parse_json(text: String) raises -> Doc:
    var p = JParser(text)
    _ = p.parse_value(0)
    p.skip_ws()
    if not p.eof():
        raise Error("trailing bytes after json")
    return p.doc.copy()
