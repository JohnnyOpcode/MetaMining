"""Expedition scoring: KDE novelty, lexical entropy, composite
novelty, coherence, gold rule, judge parsing. Pure functions; the
caller (worker) owns histories and the API-backed judge call.

Formula notes: KDE bandwidth 0.20, decay 0.97, cap 150; lexical window
15 with [a-zA-Z]{3,} tokens; composite 0.60/0.25/0.15; coherence on
[1,10] with substance/density floors; judge blend 0.35/0.65; gold bar
coherence 6.5. First-step baseline (concept vec/text in history) is a
worker behavior, matching evaluate_novelty's baseline trick.
"""

from std.math import exp, log2

from metamining.linalg import vcos


comptime KDE_TAU = 0.20
comptime KDE_GAMMA = 0.97
comptime KDE_MAXH = 150
comptime LEX_WINDOW = 15
comptime GOLD_COH_BAR = 6.5


def lex_words(text: String, minlen: Int, mut out: List[String]):
    """Alpha runs of length >= minlen, lowercased ([a-zA-Z]{n,} runs)."""
    var low = String(text.lower())
    var cur = List[UInt8]()
    for b in low.bytes():
        var v = Int(b)
        if v >= 97 and v <= 122:
            cur.append(UInt8(v))
        else:
            if len(cur) >= minlen:
                out.append(String(from_utf8_lossy=Span[UInt8](cur)))
            cur = List[UInt8]()
    if len(cur) >= minlen:
        out.append(String(from_utf8_lossy=Span[UInt8](cur)))


def _cos_dist(a: List[Float64], b: List[Float64]) -> Float64:
    var dot = 0.0
    var na = 0.0
    var nb = 0.0
    var n = len(a)
    if len(b) < n:
        n = len(b)
    for i in range(n):
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    na = na**0.5 + 1e-9
    nb = nb**0.5 + 1e-9
    var d = 1.0 - dot / (na * nb)
    if d < 0.0:
        d = 0.0
    if d > 2.0:
        d = 2.0
    return d


def kde_density(vec: List[Float64], hist: List[List[Float64]]) -> Float64:
    var n = len(hist)
    if n == 0:
        return 0.0
    var start = n - KDE_MAXH
    if start < 0:
        start = 0
    var k = n - start
    var dens = 0.0
    var wsum = 0.0
    for i in range(k):
        var h = hist[start + i].copy()
        var dist = _cos_dist(h, vec)
        var kval = exp(-dist / (KDE_TAU + 1e-6))
        var w = KDE_GAMMA ** Float64(k - 1 - i)
        dens += kval * w
        wsum += w
    var out = dens / (wsum + 1e-9)
    if out < 0.0:
        out = 0.0
    if out > 1.0:
        out = 1.0
    return out


def kde_novelty(vec: List[Float64], hist: List[List[Float64]]) -> Float64:
    var nov = 1.0 - kde_density(vec, hist)
    if nov < 0.0:
        nov = 0.0
    return nov


def count_get(d: Dict[String, Int], w: String) -> Int:
    try:
        return d[w]
    except:
        return 0


def lexical_novelty(text: String, hist_texts: List[String]) -> Float64:
    if len(hist_texts) == 0:
        return 1.0
    var words = List[String]()
    lex_words(text, 3, words)
    if len(words) == 0:
        return 0.5
    var counts = Dict[String, Int]()
    var total = 0
    var hstart = len(hist_texts) - LEX_WINDOW
    if hstart < 0:
        hstart = 0
    for i in range(hstart, len(hist_texts)):
        var hw = List[String]()
        lex_words(hist_texts[i], 3, hw)
        for j in range(len(hw)):
            counts[hw[j]] = count_get(counts, hw[j]) + 1
            total += 1
    if total == 0:
        total = 1
    var rare = 0
    var surprise = 0.0
    for i in range(len(words)):
        var c = count_get(counts, words[i])
        if c <= 1:
            rare += 1
        var prob = (Float64(c) + 0.1) / (Float64(total) + 100.0)
        surprise += -log2(prob)
    var ratio = Float64(rare) / Float64(len(words))
    var avg = surprise / Float64(len(words))
    var norm_s = (avg - 3.5) / 6.5
    if norm_s < 0.0:
        norm_s = 0.0
    if norm_s > 1.0:
        norm_s = 1.0
    var lex = 0.6 * norm_s + 0.4 * ratio
    if lex < 0.0:
        lex = 0.0
    if lex > 1.0:
        lex = 1.0
    return lex


def composite_novelty(kde: Float64, lex: Float64, cohom: Float64) -> Float64:
    var out = 0.60 * kde + 0.25 * lex + 0.15 * cohom
    if out < 0.0:
        out = 0.0
    if out > 1.0:
        out = 1.0
    return out


def coherence_base(text: String, cos_loc: Float64) -> Float64:
    """Base coherence [~0.5, 10]: location continuity x substance x density.

    cos_loc is cosine(candidate, location) for semantic vectors, or the
    lexical-overlap stand-in (same 0..1 shape) for hash-BOW vectors.
    """
    var t = (cos_loc - 0.15) / 0.55
    if t < 0.0:
        t = 0.0
    var local = 4.0 + 6.0 * t
    if local < 2.0:
        local = 2.0
    if local > 10.0:
        local = 10.0
    var words = List[String]()
    lex_words(text, 2, words)
    var wc = len(words)
    var substance = Float64(wc) / 50.0
    if substance < 0.4:
        substance = 0.4
    if substance > 1.0:
        substance = 1.0
    var seen = Dict[String, Int]()
    var unique = 0
    for i in range(wc):
        if count_get(seen, words[i]) == 0:
            unique += 1
        seen[words[i]] = 1
    var denom = wc
    if denom < 1:
        denom = 1
    var density = Float64(unique) / Float64(denom) / 0.50
    if density < 0.6:
        density = 0.6
    if density > 1.0:
        density = 1.0
    return local * substance * density


def round1(x: Float64) -> Float64:
    return Float64(Int(x * 10.0 + 0.5)) / 10.0


def clamp_coh(x: Float64) -> Float64:
    if x < 1.0:
        return 1.0
    if x > 10.0:
        return 10.0
    return x


def blend_judge(base: Float64, judge: Float64) -> Float64:
    return round1(clamp_coh(0.35 * base + 0.65 * judge))


def is_gold(nov: Float64, coh10: Float64, gold_thresh: Float64) -> Bool:
    return nov >= gold_thresh and coh10 >= GOLD_COH_BAR


def median_vote(votes: List[Float64]) -> Float64:
    """Median of judge votes; even counts average the middle two."""
    var n = len(votes)
    if n == 0:
        return 6.0
    var s = votes.copy()
    for i in range(1, n):
        var v = s[i]
        var j = i - 1
        while j >= 0 and s[j] > v:
            s[j + 1] = s[j]
            j -= 1
        s[j + 1] = v
    var mid = n // 2
    if n % 2 == 1:
        return s[mid]
    return (s[mid - 1] + s[mid]) / 2.0


def novelty_stationary(series: List[Float64]) -> Bool:
    """True when novelty has flatlined: trailing-8 mean within 0.02 of
    the prior-8 mean AND least-squares slope over the trailing 8 within
    0.002/step. Needs at least 16 samples."""
    var n = len(series)
    if n < 16:
        return False
    var m1 = 0.0
    for i in range(n - 16, n - 8):
        m1 += series[i]
    m1 /= 8.0
    var m2 = 0.0
    for i in range(n - 8, n):
        m2 += series[i]
    m2 /= 8.0
    var d = m2 - m1
    if d < 0.0:
        d = -d
    if d > 0.02:
        return False
    var sxy = 0.0
    for k in range(8):
        sxy += (Float64(k) - 3.5) * (series[n - 8 + k] - m2)
    var slope = sxy / 42.0
    if slope < 0.0:
        slope = -slope
    return slope <= 0.002


def vein_best_cos(vec: List[Float64], veins: List[List[Float64]]) -> Float64:
    """Max cosine of vec against vein vecs; -1.0 when there are none."""
    var best = -1.0
    if len(vec) == 0:
        return best
    for i in range(len(veins)):
        var vv = veins[i].copy()
        if len(vv) == 0:
            continue
        var c = vcos(vec, vv)
        if c > best:
            best = c
    return best


def vein_repulse_factor(vec: List[Float64], veins: List[List[Float64]]) -> Float64:
    """Novelty multiplier vs the vein library: 0.5 when the candidate
    sits almost on top of a known vein (max cosine above 0.97)."""
    if vein_best_cos(vec, veins) > 0.97:
        return 0.5
    return 1.0


def vein_nearest(
    vec: List[Float64], veins: List[List[Float64]], mut out: List[Float64]
) -> Bool:
    """Copy the nearest same-dim vein vec into out. False when none."""
    var bi = -1
    var bc = -1.0
    if len(vec) == 0:
        return False
    for i in range(len(veins)):
        var vv = veins[i].copy()
        if len(vv) != len(vec):
            continue
        var c = vcos(vec, vv)
        if c > bc:
            bc = c
            bi = i
    if bi < 0:
        return False
    var bn = veins[bi].copy()
    for j in range(len(bn)):
        out.append(bn[j])
    return True


def parse_judge(text: String) -> Float64:
    """First 1-2 digit run with word boundaries; default 6.0; clamp 1-10."""
    var bytes = List[Int]()
    for b in text.bytes():
        bytes.append(Int(b))
    var i = 0
    while i < len(bytes):
        var c = bytes[i]
        if c >= 48 and c <= 57:
            var j = i
            while j < len(bytes) and bytes[j] >= 48 and bytes[j] <= 57:
                j += 1
            var left_ok = i == 0 or not _is_word(bytes[i - 1])
            var right_ok = j >= len(bytes) or not _is_word(bytes[j])
            if left_ok and right_ok and (j - i == 1 or j - i == 2):
                var v = 0
                var k = i
                while k < j:
                    v = v * 10 + (bytes[k] - 48)
                    k += 1
                if v < 1:
                    v = 1
                if v > 10:
                    v = 10
                return Float64(v)
            i = j
        else:
            i += 1
    return 6.0


def _is_word(c: Int) -> Bool:
    if c >= 48 and c <= 57:
        return True
    if c >= 65 and c <= 90:
        return True
    if c >= 97 and c <= 122:
        return True
    return c == 95
