"""Structural web tests: every control wired, every fetch routed.

Pure-static cross-reference between web/index.html, web/app.js, and the
Mojo route table. Dynamic lookups (getElementById(var), fetch(url)) are
skipped by construction; the reverse direction (every id referenced
somewhere) covers existence.
"""

from std.testing import assert_equal, assert_true

from metamining.libc import file_read_all


def _bytes(s: String) -> List[Int]:
    var out = List[Int]()
    for b in s.bytes():
        out.append(Int(b))
    return out.copy()


def _scan_strings(src: String) -> Dict[String, Bool]:
    """Every single/double-quoted literal outside comments."""
    var out = Dict[String, Bool]()
    var b = _bytes(src)
    var i = 0
    var n = len(b)
    while i < n:
        var c = b[i]
        if c == 47 and i + 1 < n and b[i + 1] == 47:
            while i < n and b[i] != 10:
                i += 1
            continue
        if c == 47 and i + 1 < n and b[i + 1] == 42:
            i += 2
            while i + 1 < n and not (b[i] == 42 and b[i + 1] == 47):
                i += 1
            i += 2
            continue
        if c == 34 or c == 39:
            var q = c
            i += 1
            var lit = String()
            while i < n and b[i] != q:
                if b[i] == 92 and i + 1 < n:
                    i += 1
                    lit += chr(b[i])
                    i += 1
                    continue
                lit += chr(b[i])
                i += 1
            i += 1
            out[lit] = True
            continue
        i += 1
    return out^


def _find_all(hay: List[Int], needle: List[Int]) -> List[Int]:
    var out = List[Int]()
    if len(needle) == 0 or len(needle) > len(hay):
        return out.copy()
    var i = 0
    while i <= len(hay) - len(needle):
        var ok = True
        for j in range(len(needle)):
            if hay[i + j] != needle[j]:
                ok = False
                break
        if ok:
            out.append(i)
            i += len(needle)
        else:
            i += 1
    return out.copy()


def _call_lits(js: List[Int], fname: String) -> List[String]:
    """Literal first args of fname( calls; concat prefix gets trailing +."""
    var out = List[String]()
    var fb = _bytes(fname)
    var calls = _find_all(js, fb)
    for t in range(len(calls)):
        var i = calls[t] + len(fb)
        if i < len(js) and js[i] == 40:
            i += 1
        else:
            continue
        while i < len(js) and (js[i] == 32 or js[i] == 9 or js[i] == 10):
            i += 1
        if i >= len(js) or (js[i] != 34 and js[i] != 39):
            continue
        var q = js[i]
        i += 1
        var lit = String()
        while i < len(js) and js[i] != q:
            if js[i] == 92 and i + 1 < len(js):
                i += 1
                lit += chr(js[i])
                i += 1
                continue
            lit += chr(js[i])
            i += 1
        i += 1
        while i < len(js) and (js[i] == 32 or js[i] == 9):
            i += 1
        if i < len(js) and js[i] == 43:
            lit += "+"
        out.append(lit)
    return out.copy()


def _html_ids(html: String) -> List[String]:
    var out = List[String]()
    var b = _bytes(html)
    for pat_i in range(2):
        var pat = _bytes('id="') if pat_i == 0 else _bytes("id='")
        var q = 34 if pat_i == 0 else 39
        var hits = _find_all(b, pat)
        for t in range(len(hits)):
            var i = hits[t] + len(pat)
            var lit = String()
            while i < len(b) and b[i] != q:
                lit += chr(b[i])
                i += 1
            var dup = False
            for k in range(len(out)):
                if out[k] == lit:
                    dup = True
            if not dup:
                out.append(lit)
    return out.copy()


def _keys(d: Dict[String, Bool]) -> List[String]:
    var out = List[String]()
    for k in d.keys():
        out.append(k)
    return out.copy()


def _has_prefix(keys: List[String], ident: String) -> Bool:
    for i in range(len(keys)):
        var k = keys[i]
        if k.byte_length() >= 3 and ident.startswith(k) and ident != k:
            return True
    return False


def _in_hx_form(hb: List[Int], at: Int) -> Bool:
    var i = at
    var seen_form = False
    var seen_close = False
    while i > 0 and at - i < 6000:
        if i + 5 < len(hb) and hb[i] == 60 and hb[i + 1] == 102 and hb[i + 2] == 111 and hb[i + 3] == 114 and hb[i + 4] == 109:
            seen_form = True
            break
        if i + 6 < len(hb) and hb[i] == 60 and hb[i + 1] == 47 and hb[i + 2] == 102 and hb[i + 3] == 111 and hb[i + 4] == 114 and hb[i + 5] == 109:
            seen_close = True
            break
        i -= 1
    if not seen_form or seen_close:
        return False
    var tag = String()
    var j = i
    while j < len(hb) and hb[j] != 62 and j - i < 2000:
        tag += chr(hb[j])
        j += 1
    return tag.find("hx-post") >= 0 or tag.find("hx-get") >= 0


def _tag_has(hb: List[Int], at: Int, marker: List[Int]) -> Bool:
    var lo = at
    while lo > 0 and hb[lo] != 60 and at - lo < 2000:
        lo -= 1
    var hi = at
    while hi < len(hb) and hb[hi] != 62 and hi - at < 2000:
        hi += 1
    if hi - lo > 4000:
        return False
    for i in range(lo, hi - len(marker) + 1):
        var ok = True
        for j in range(len(marker)):
            if hb[i + j] != marker[j]:
                ok = False
                break
        if ok:
            return True
    return False


def _drop_last(s: String) -> String:
    var b = _bytes(s)
    var out = String()
    for i in range(len(b) - 1):
        out += chr(b[i])
    return out


def _strip_query(p: String) -> String:
    var out = String()
    for b in p.bytes():
        if Int(b) == 63:
            break
        out += chr(Int(b))
    return out


def test_ids_exist() raises:
    var js = file_read_all("web/app.js")
    var html = file_read_all("web/index.html")
    assert_true(js.byte_length() > 10000)
    assert_true(html.byte_length() > 1000)
    var ids = _html_ids(html)
    assert_true(len(ids) > 50)
    var idset = Dict[String, Bool]()
    for i in range(len(ids)):
        idset[ids[i]] = True
    var jb = _bytes(js)
    var missing = List[String]()
    var lits = _call_lits(jb, "getElementById")
    var dlits = _call_lits(jb, "$")
    for i in range(len(dlits)):
        lits.append(dlits[i])
    for i in range(len(lits)):
        var lit = lits[i]
        if lit.endswith("+"):
            var pre = _drop_last(lit)
            var any_hit = False
            for k in range(len(ids)):
                if ids[k].startswith(pre):
                    any_hit = True
                    break
            if not any_hit:
                missing.append(lit)
            continue
        try:
            _ = idset[lit]
        except:
            missing.append(lit)
    for i in range(len(missing)):
        print("missing id: " + missing[i])
    assert_equal(len(missing), 0)
    print("ids exist ok (" + String(len(ids)) + " ids, " + String(len(lits)) + " lookups)")


def test_fetches_routed() raises:
    var js = file_read_all("web/app.js")
    var html = file_read_all("web/index.html")
    var srv = file_read_all("src/metamining/server.mojo")
    var js_lits = _scan_strings(js)
    var html_lits = _scan_strings(html)
    var srv_lits = _scan_strings(srv)
    var paths = List[String]()
    for lit in js_lits.keys():
        if lit.startswith("/api/") or lit.startswith("/frag/") or lit.startswith("/events"):
            var p = _strip_query(lit)
            if p == "/api/" or p == "/frag/":
                continue
            var dup = False
            for k in range(len(paths)):
                if paths[k] == p:
                    dup = True
            if not dup:
                paths.append(p)
    for lit in html_lits.keys():
        if lit.startswith("/api/") or lit.startswith("/frag/") or lit.startswith("/events"):
            var p = _strip_query(lit)
            if p == "/api/" or p == "/frag/":
                continue
            var dup = False
            for k in range(len(paths)):
                if paths[k] == p:
                    dup = True
            if not dup:
                paths.append(p)
    assert_true(len(paths) > 10)
    var missing = List[String]()
    for i in range(len(paths)):
        try:
            _ = srv_lits[paths[i]]
        except:
            missing.append(paths[i])
    for i in range(len(missing)):
        print("unrouted: " + missing[i])
    assert_equal(len(missing), 0)
    print("fetches routed ok (" + String(len(paths)) + " paths)")


def test_ids_referenced() raises:
    var js = file_read_all("web/app.js")
    var html = file_read_all("web/index.html")
    var js_lits = _scan_strings(js)
    var js_keys = _keys(js_lits)
    var ids = _html_ids(html)
    var hb = _bytes(html)
    var hx = _bytes("hx-")
    # Documented anchors: section containers, probe hooks, class-queried
    # filter pills (.pill + data-filter, never looked up by id), and the
    # journal download link (functional href+download, needs no JS).
    var anchors = List[String]()
    anchors.append("journal")
    anchors.append("shape-panel")
    anchors.append("shape-data")
    anchors.append("shape-table")
    anchors.append("diff-panel")
    anchors.append("topo")
    anchors.append("api")
    anchors.append("modal-next-row")
    anchors.append("pill-all")
    anchors.append("pill-gold")
    anchors.append("pill-loops")
    var dead = List[String]()
    for i in range(len(ids)):
        var anchored = False
        for a in range(len(anchors)):
            if anchors[a] == ids[i]:
                anchored = True
        if anchored:
            continue
        try:
            _ = js_lits[ids[i]]
            continue
        except:
            pass
        if _has_prefix(js_keys, ids[i]):
            continue
        var pat = _bytes('id="' + ids[i] + '"')
        var hits = _find_all(hb, pat)
        if len(hits) == 0:
            pat = _bytes("id='" + ids[i] + "'")
            hits = _find_all(hb, pat)
        var wired = False
        for t in range(len(hits)):
            if _tag_has(hb, hits[t], hx) or _in_hx_form(hb, hits[t]):
                wired = True
                break
        if not wired:
            dead.append(ids[i])
    for i in range(len(dead)):
        print("dead id: " + dead[i])
    assert_equal(len(dead), 0)
    print("ids referenced ok")


def test_scatter_hidden_hint() raises:
    """Scatter mode with Balls+Gold toggled off must say markers are hidden.

    Regression: with both marker toggles off, drawScatter3 rendered a bare
    grid that read as "nothing plotted" even with data loaded (HUD still
    showed Points: N). The 3D renderer must paint an in-canvas hint naming
    the toggles that hide the cloud.
    """
    var js = file_read_all("web/app.js")
    var draw = js.find("function drawScatter3")
    assert_true(draw >= 0)
    var h1 = js.find("points hidden")
    var h2 = js.find("Balls / Gold")
    var h3 = js.find("!showBalls3d && !showGold3d")
    assert_true(h1 > draw)
    assert_true(h2 > draw)
    assert_true(h3 > draw)
    print("scatter hidden-markers hint ok")


def test_gold_ball_scale() raises:
    """3D gold markers must be ~2x a normal ball, not a blob.

    Regression: gold used an 18*dpr shadow halo plus a 1.6x ring that
    swallowed the cloud. The gold branch of the 3D node painter must
    keep the whole marker near 2x a normal ball (normal r = rad * 0.9):
    small core, faint glow, close thin ring. Both balls halved together
    at the shared rad definition so the ratio survives.
    """
    var js = file_read_all("web/app.js")
    var draw = js.find("function drawScatter3")
    assert_true(draw >= 0)
    var rad = js.find("Math.max(1.9, 3.25 * pp.scale)")
    var core = js.find("var gr = rad * 1.4")
    var blur = js.find("shadowBlur = 4 * dpr")
    var ring = js.find("gr * 1.2")
    assert_true(rad > draw)
    assert_true(core > draw)
    assert_true(blur > draw)
    assert_true(ring > draw)
    assert_true(js.find("Math.max(3.8, 6.5 * pp.scale)") < 0)
    assert_true(js.find("shadowBlur = 18 * dpr") < 0)
    assert_true(js.find("gr * 1.6") < 0)
    print("gold ball scale ok")


def main() raises:
    test_ids_exist()
    test_fetches_routed()
    test_ids_referenced()
    test_scatter_hidden_hint()
    test_gold_ball_scale()
    print("ALL WEB TESTS PASSED")
