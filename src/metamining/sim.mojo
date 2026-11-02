"""Deterministic simulated model backend.

Seeded xorshift PRNG, template generation (60-90 word texts so the
substance factor behaves), and hash-BOW-64 vectors with genuine cosine
geometry (shared words -> similar vectors). Same (seed, branch, step)
always yields the same finding, keeping runs reproducible and tests
hermetic.
"""

from metamining.scoring import lex_words


struct SimRng(ImplicitlyCopyable):
    var s: UInt64

    def __init__(out self, seed: Int):
        var v = UInt64(seed) * UInt64(1000003) + UInt64(97)
        if v == UInt64(0):
            v = UInt64(1)
        self.s = v

    def next_u64(mut self) -> UInt64:
        var x = self.s
        x ^= x >> UInt64(12)
        x ^= x << UInt64(25)
        x ^= x >> UInt64(27)
        self.s = x
        return x

    def next_unit(mut self) -> Float64:
        var v = self.next_u64() >> UInt64(11)
        return Float64(v) / 9007199254740992.0

    def next_range(mut self, lo: Float64, hi: Float64) -> Float64:
        return lo + (hi - lo) * self.next_unit()

    def pick(mut self, n: Int) -> Int:
        if n <= 0:
            return 0
        return Int(self.next_u64() % UInt64(n))


def fnv1a(s: String) -> UInt64:
    var h = UInt64(1469598103) * UInt64(10000000000) + UInt64(9346656037)
    for b in s.bytes():
        h ^= UInt64(Int(b))
        h *= UInt64(1099511628211)
    return h


def sim_stream(seed: Int, branch: Int, step: Int) -> SimRng:
    var h = UInt64(seed) * UInt64(1000003)
    h ^= UInt64(branch + 1) * UInt64(9176)
    h ^= UInt64(step + 1) * UInt64(1543)
    var lo = Int(h & UInt64(9223372036854775807))
    return SimRng(lo)


def _lens() -> List[String]:
    var l = List[String]()
    l.append("thermodynamic cost accounting")
    l.append("topological memory")
    l.append("category-theoretic duality")
    l.append("ecological succession")
    l.append("error-correcting codes")
    l.append("market microstructure")
    l.append("embryonic morphogenesis")
    l.append("proof-theoretic strength")
    l.append("swarm coordination")
    l.append("metabolic scaling")
    l.append("sheaf gluing conditions")
    l.append("adversarial robustness")
    l.append("crystal lattice defects")
    l.append("narrative grammar")
    l.append("renormalization flow")
    l.append("quorum sensing")
    return l.copy()


def _moves() -> List[String]:
    var m = List[String]()
    m.append("invert the usual causal arrow and price the reversal")
    m.append("treat the boundary as the object and the bulk as noise")
    m.append("look for the conserved quantity nobody is tracking")
    m.append("replace the average with the extremal case and see what breaks")
    m.append("ask what the system forgets fastest, then amplify the residue")
    m.append("translate the claim into a betting market and clear it")
    m.append("find the symmetry, then mine the symmetry-breaking term")
    m.append("compress the idea until only the surprise remains")
    m.append("run the process backwards from the desired fixed point")
    m.append("split the concept along its least-examined joint")
    m.append("measure second-order effects and promote one to first-order")
    m.append("embed the problem in one higher dimension, then project back")
    return m.copy()


def _metrics() -> List[String]:
    var m = List[String]()
    m.append("mutual information")
    m.append("effective rank")
    m.append("escape rate")
    m.append("mixing time")
    m.append("surprise mass")
    m.append("basin volume")
    m.append("return probability")
    m.append("spectral gap")
    return m.copy()


def _mechanisms() -> List[String]:
    var m = List[String]()
    m.append("contrastive pressure")
    m.append("topological defect")
    m.append("resonant coupling")
    m.append("entropic ratchet")
    m.append("symmetry lock")
    m.append("gradient shadow")
    m.append("memory kernel")
    m.append("bifurcation cascade")
    return m.copy()


def _predictions() -> List[String]:
    var m = List[String]()
    m.append("a sharp phase change in probe accuracy")
    m.append("heavy-tailed novelty bursts")
    m.append("collapse of the dominant loop")
    m.append("emergence of a second void")
    m.append("sudden coherence recovery")
    m.append("a new stable Pareto knee")
    m.append("oscillation between two basins")
    m.append("silent saturation with no signal")
    return m.copy()


def sim_gen_text(
    concept: String,
    location: String,
    persona: Int,
    branch: Int,
    step: Int,
    temp: Float64,
    seed: Int,
) -> String:
    var rng = sim_stream(seed, branch, step)
    var lenses = _lens()
    var moves = _moves()
    var metrics = _metrics()
    var mechs = _mechanisms()
    var preds = _predictions()
    var pool = 4 + Int(temp * 12.0)
    if pool > len(lenses):
        pool = len(lenses)
    if pool < 1:
        pool = 1
    var prot = persona % pool
    if prot < 0:
        prot += pool
    var mrot = persona % len(moves)
    if mrot < 0:
        mrot += len(moves)
    var lens = lenses[(rng.pick(pool) + prot) % pool]
    var lens2 = lenses[rng.pick(len(lenses))]
    var lens3 = lenses[rng.pick(len(lenses))]
    var move = moves[(rng.pick(len(moves)) + mrot) % len(moves)]
    var move2 = moves[rng.pick(len(moves))]
    var metric = metrics[rng.pick(len(metrics))]
    var mech = mechs[rng.pick(len(mechs))]
    var pred = preds[rng.pick(len(preds))]
    var depth = 1 + rng.pick(3)
    var mark = String("~") if rng.next_unit() < 0.5 else String("!")
    return (
        String("Vein hypothesis ")
        + String(step)
        + mark
        + " ["
        + concept
        + "] crossed with ["
        + lens
        + "] suggests we "
        + move
        + ". Current front: "
        + location
        + ". Concretely, "
        + move2
        + " while tracking "
        + metric
        + " across "
        + String(depth)
        + " levels of "
        + lens2
        + ", watching where "
        + mech
        + " saturates first. If the "
        + mech
        + " holds, expect "
        + pred
        + "; otherwise the residue points back at "
        + lens3
        + " and the search continues there."
    )


def sim_embed(text: String, mut out: List[Float64]):
    """Hash-BOW-64 unit vector: shared words => similar vectors."""
    var acc = List[Float64]()
    for _ in range(64):
        acc.append(0.0)
    var words = List[String]()
    lex_words(text, 2, words)
    for i in range(len(words)):
        var d = Int(fnv1a(words[i]) % UInt64(64))
        acc[d] = acc[d] + 1.0
    var norm = 0.0
    for j in range(64):
        norm += acc[j] * acc[j]
    norm = norm**0.5
    if norm <= 1e-18:
        for _ in range(64):
            out.append(0.0)
        return
    for j in range(64):
        out.append(acc[j] / norm)
