"""Meta Model API client: POST /v1/responses + GET /v1/models.

Speaks the OpenAI-compatible Responses shape that api.meta.ai serves:
Bearer auth, {"model","instructions","input"} in, output[].content[]
text out. Pure functions (api_path/extract/parse_models) stay offline
testable; only meta_* touch the network.
"""

from std.math import isinf, isnan

from metamining.http import http_get, http_post_json, parse_endpoint_url
from metamining.libc import file_read_all, mono_ms, msleep
from metamining.json import (
    Doc,
    J_ARR,
    J_OBJ,
    J_STR,
    doc_at,
    doc_find,
    doc_kind,
    doc_len,
    doc_num,
    doc_onum,
    doc_ostr,
    doc_root,
    j_escape,
    j_render_num,
    parse_json,
)


struct MetaCfg(ImplicitlyCopyable):
    var base_url: String
    var api_key: String
    var model: String
    var embed_model: String
    var embed_endpoint: String
    var embed_doc_prefix: String
    var embed_query_prefix: String

    def __init__(
        out self,
        base_url: String,
        api_key: String,
        model: String,
        embed_model: String,
        embed_endpoint: String = "",
        embed_doc_prefix: String = "",
        embed_query_prefix: String = "",
    ):
        self.base_url = base_url
        self.api_key = api_key
        self.model = model
        self.embed_model = embed_model
        self.embed_endpoint = embed_endpoint
        self.embed_doc_prefix = embed_doc_prefix
        self.embed_query_prefix = embed_query_prefix


def embed_base(cfg: MetaCfg) -> String:
    """Base URL for embedding calls. A dedicated embed endpoint
    (e.g. a local llama-server) wins when set; otherwise embeddings
    ride the chat endpoint."""
    if cfg.embed_endpoint != "":
        return cfg.embed_endpoint
    return cfg.base_url


def embed_input(prefix: String, text: String) -> String:
    """Apply an instruction prefix (nomic-style 'search_document: ')
    to one embed input. A blank prefix is a no-op, which is the
    correct setting for backends without instruction prefixes."""
    if prefix == "":
        return text
    return prefix + text


struct MetaOut(Copyable, Movable):
    var ok: Bool
    var text: String
    var err: String
    var ms: Int
    var in_tok: Int
    var out_tok: Int
    var tries: Int

    def __init__(
        out self, ok: Bool, text: String, err: String, ms: Int, in_tok: Int, out_tok: Int, tries: Int
    ):
        self.ok = ok
        self.text = text
        self.err = err
        self.ms = ms
        self.in_tok = in_tok
        self.out_tok = out_tok
        self.tries = tries


struct TokUsage(ImplicitlyCopyable):
    var inp: Int
    var out: Int

    def __init__(out self, in_tok: Int, out_tok: Int):
        self.inp = in_tok
        self.out = out_tok


def parse_usage(body: String) -> TokUsage:
    var u = TokUsage(0, 0)
    var d: Doc
    try:
        d = parse_json(body)
    except:
        return u
    var us = doc_find(d, doc_root(d), "usage")
    if us < 0:
        return u
    try:
        var fi = doc_onum(d, us, "input_tokens")
        if not (isinf(fi) or isnan(fi)):
            u.inp = Int(fi)
    except:
        pass
    try:
        var fo = doc_onum(d, us, "output_tokens")
        if not (isinf(fo) or isnan(fo)):
            u.out = Int(fo)
    except:
        pass
    return u


struct ModelRates(ImplicitlyCopyable):
    var inp: Float64
    var out: Float64

    def __init__(out self, in_r: Float64, out_r: Float64):
        self.inp = in_r
        self.out = out_r


def model_rates(model: String) -> ModelRates:
    """USD per 1M tokens from Meta's published Model API pricing.

    Spark standard $1.25/$4.25, Contributor $0.10/$0.20, Wonder $4/$20.
    Returns (-1, -1) for unknown ids so cost shows n/a, never a guess.
    """
    var m = String(model.strip()).lower()
    if m.find("contributor") >= 0:
        return ModelRates(0.10, 0.20)
    if m == "muse-spark-1.3" or m == "muse-spark-1.2" or m == "muse-spark-1.1":
        return ModelRates(1.25, 4.25)
    if m == "muse-wonder-1.0" or m == "muse-wonder-full-1.0":
        return ModelRates(4.0, 20.0)
    return ModelRates(-1.0, -1.0)


def model_known(ids: List[String], m: String) -> Bool:
    """True when model id m matches an endpoint list entry.

    Trimmed, case-insensitive: validation is a guardrail that must never
    block a config the endpoint itself would accept. Pure: unit-testable.
    """
    var want = String(m.strip()).lower()
    if want == "":
        return False
    for i in range(len(ids)):
        var e = ids[i]
        if String(e.strip()).lower() == want:
            return True
    return False


def parse_pricing_json(text: String) -> Dict[String, String]:
    """pricing.json rows -> lower(model-id) => "inp,out" USD per 1M tokens.

    Shape: [{"model": "muse-spark-1.3", "in": 1.25, "out": 4.25}, ...].
    Bad rows (blank id, non-positive rates) are skipped; bad JSON or a
    non-array root yields an empty map. Pure: unit-testable without disk.
    """
    var out = Dict[String, String]()
    var t = String(text.strip())
    if t == "":
        return out.copy()
    var d: Doc
    try:
        d = parse_json(t)
    except:
        return out.copy()
    var r = doc_root(d)
    if doc_kind(d, r) != J_ARR:
        return out.copy()
    for i in range(doc_len(d, r)):
        var row = doc_at(d, r, i)
        if doc_kind(d, row) != J_OBJ:
            continue
        var mid = String(doc_ostr(d, row, "model").strip()).lower()
        if mid == "":
            continue
        var inp = doc_onum(d, row, "in")
        var outp = doc_onum(d, row, "out")
        if not (inp > 0.0 and outp > 0.0):
            continue
        out[mid] = j_render_num(inp) + "," + j_render_num(outp)
    return out.copy()


def load_pricing_file(path: String) -> Dict[String, String]:
    """Read pricing.json (missing/blank file = empty overrides)."""
    var raw = file_read_all(path)
    if raw == "":
        return Dict[String, String]()
    return parse_pricing_json(raw)


def model_rates_over(model: String, over: Dict[String, String]) -> ModelRates:
    """model_rates with pricing.json overrides (exact id match) first."""
    var m = String(model.strip()).lower()
    if m != "":
        var hit = String()
        try:
            hit = over[m]
        except:
            return model_rates(model)
        var comma = hit.find(",")
        if comma > 0:
            try:
                var inp = Float64(String(hit[byte=0:comma]))
                var outp = Float64(
                    String(hit[byte=comma + 1 : hit.byte_length()])
                )
                if inp > 0.0 and outp > 0.0:
                    return ModelRates(inp, outp)
            except:
                pass
    return model_rates(model)


def api_path(base: String, leaf: String) -> String:
    var b = base
    if b.endswith("/"):
        var cut = String(b[byte=0 : b.byte_length() - 1])
        b = cut
    if b.endswith("/responses"):
        if leaf == "responses":
            return b
        var root = String(b[byte=0 : b.byte_length() - 10])
        return root + "/" + leaf
    if b == "":
        return "/" + leaf
    return b + "/" + leaf


def extract_text(body: String) raises -> String:
    """Best-effort output_text join from a Responses payload."""
    var d = parse_json(body)
    var r = doc_root(d)
    var first = _walk_output(d, r, True)
    if first != "":
        return first
    return _walk_output(d, r, False)


def _walk_output(d: Doc, r: Int, output_text_only: Bool) -> String:
    var acc = List[String]()
    var output = doc_find(d, r, "output")
    if doc_kind(d, output) == J_STR:
        return doc_ostr(d, r, "output")
    if doc_kind(d, output) != J_ARR:
        return String()
    for i in range(doc_len(d, output)):
        var item = doc_at(d, output, i)
        if doc_kind(d, item) != J_OBJ:
            continue
        var content = doc_find(d, item, "content")
        if doc_kind(d, content) == J_ARR:
            for j in range(doc_len(d, content)):
                var c = doc_at(d, content, j)
                if doc_kind(d, c) != J_OBJ:
                    continue
                var t = doc_ostr(d, c, "text")
                if t == "":
                    continue
                if output_text_only and doc_ostr(d, c, "type") != "output_text":
                    continue
                acc.append(t)
        else:
            var t = doc_ostr(d, item, "text")
            if t == "":
                continue
            if output_text_only and doc_ostr(d, item, "type") != "output_text":
                continue
            acc.append(t)
    var out = String()
    for k in range(len(acc)):
        if k > 0:
            out += "\n\n"
        out += acc[k]
    return out


def error_message(body: String) -> String:
    try:
        var d = parse_json(body)
        var r = doc_root(d)
        var e = doc_find(d, r, "error")
        if doc_kind(d, e) == J_STR:
            return doc_ostr(d, r, "error")
        if doc_kind(d, e) == J_OBJ:
            var m = doc_ostr(d, e, "message")
            if m != "":
                return m
        return String()
    except:
        return String()


def parse_models(body: String, mut out: List[String]) raises -> String:
    """Fill out with model ids. Returns "" on success else error text."""
    var d = parse_json(body)
    var r = doc_root(d)
    var data = doc_find(d, r, "data")
    if doc_kind(d, data) != J_ARR:
        var em = error_message(body)
        if em != "":
            return em
        return String("no data[] in models response")
    for i in range(doc_len(d, data)):
        var item = doc_at(d, data, i)
        var mid = doc_ostr(d, item, "id")
        if mid != "":
            out.append(mid)
    return String()


def _retryable_status(status: Int) -> Bool:
    """429 + 5xx (+ status 0: peer closed without a response)."""
    if status == 0:
        return True
    if status == 429:
        return True
    return status >= 500


def _retry_sleep(tries: Int):
    if tries == 1:
        msleep(1000)
    elif tries == 2:
        msleep(2000)


def meta_models(cfg: MetaCfg, mut out: List[String]) -> String:
    var url = parse_endpoint_url(cfg.base_url)
    if not url.ok:
        return String("bad endpoint url")
    var tries = 0
    while True:
        tries += 1
        var r = http_get(url, api_path(url.base, "models"), "Bearer " + cfg.api_key)
        if not r.ok:
            if tries >= 3:
                return r.err
            _retry_sleep(tries)
            continue
        if r.status == 401 or r.status == 403:
            return String("unauthorized (check api key)")
        if r.status != 200:
            var em = error_message(r.body)
            if em == "":
                em = "http " + String(r.status)
            if not _retryable_status(r.status):
                return em
            if tries >= 3:
                return em
            _retry_sleep(tries)
            continue
        try:
            return parse_models(r.body, out)
        except:
            return String("bad models json")


def parse_embeddings(body: String, mut out: List[List[Float64]]) raises -> String:
    """Fill out with one vector per input. "" on success else error text."""
    var d = parse_json(body)
    var r = doc_root(d)
    var data = doc_find(d, r, "data")
    if doc_kind(d, data) != J_ARR:
        var em = error_message(body)
        if em != "":
            return em
        return String("no data[] in embeddings response")
    for i in range(doc_len(d, data)):
        var item = doc_at(d, data, i)
        var emb = doc_find(d, item, "embedding")
        if doc_kind(d, emb) != J_ARR or doc_len(d, emb) == 0:
            return String("bad embedding vector")
        var vec = List[Float64]()
        for j in range(doc_len(d, emb)):
            vec.append(doc_num(d, doc_at(d, emb, j)))
        out.append(vec.copy())
    return String()


def meta_embed(cfg: MetaCfg, texts: List[String], mut out: List[List[Float64]]) -> String:
    if cfg.embed_model == "":
        return String("no embedding model configured")
    var url = parse_endpoint_url(embed_base(cfg))
    if not url.ok:
        return String("bad endpoint url")
    var body = String('{"model":"') + j_escape(cfg.embed_model) + '","input":['
    for i in range(len(texts)):
        if i > 0:
            body += ","
        body += '"' + j_escape(texts[i]) + '"'
    body += "]}"
    var tries = 0
    while True:
        tries += 1
        var r = http_post_json(
            url, api_path(url.base, "embeddings"), body, "Bearer " + cfg.api_key
        )
        if not r.ok:
            if tries >= 3:
                return r.err
            _retry_sleep(tries)
            continue
        if r.status == 401 or r.status == 403:
            return String("unauthorized (check api key)")
        if r.status != 200:
            var em = error_message(r.body)
            if em == "":
                em = "http " + String(r.status)
            if not _retryable_status(r.status):
                return em
            if tries >= 3:
                return em
            _retry_sleep(tries)
            continue
        try:
            return parse_embeddings(r.body, out)
        except:
            return String("bad embeddings json")


def meta_respond(
    cfg: MetaCfg, instructions: String, prompt: String, temp: Float64, max_tok: Int = 4096
) -> MetaOut:
    var url = parse_endpoint_url(cfg.base_url)
    if not url.ok:
        var bad = MetaOut(False, String(), String("bad endpoint url"), 0, 0, 0, 0)
        return bad.copy()
    var body = (
        String('{"model":"')
        + j_escape(cfg.model)
        + '","instructions":"'
        + j_escape(instructions)
        + '","input":"'
        + j_escape(prompt)
        + '","temperature":'
        + j_render_num(temp)
        + ',"max_output_tokens":'
        + String(max_tok)
        + "}"
    )
    var tries = 0
    var ms_total = 0
    var in_total = 0
    var out_total = 0
    while True:
        tries += 1
        var t0 = mono_ms()
        var r = http_post_json(
            url, api_path(url.base, "responses"), body, "Bearer " + cfg.api_key
        )
        var t1 = mono_ms()
        if t0 >= 0 and t1 >= t0:
            ms_total += t1 - t0
        if not r.ok:
            if tries >= 3:
                var terr = MetaOut(False, String(), r.err, ms_total, 0, 0, tries)
                return terr.copy()
            _retry_sleep(tries)
            continue
        if r.status == 401 or r.status == 403:
            var em0 = String("unauthorized - check api key")
            var unauth = MetaOut(False, String(), em0, ms_total, 0, 0, tries)
            return unauth.copy()
        if r.status != 200:
            var em = error_message(r.body)
            if em == "":
                em = "http " + String(r.status)
            if not _retryable_status(r.status):
                var herr = MetaOut(False, String(), em, ms_total, 0, 0, tries)
                return herr.copy()
            if tries >= 3:
                var herr3 = MetaOut(False, String(), em, ms_total, 0, 0, tries)
                return herr3.copy()
            _retry_sleep(tries)
            continue
        var use = parse_usage(r.body)
        in_total += use.inp
        out_total += use.out
        try:
            var text = extract_text(r.body)
            if text != "":
                var good = MetaOut(True, text, String(), ms_total, in_total, out_total, tries)
                return good.copy()
            var em2 = error_message(r.body)
            if em2 != "":
                var api_err = MetaOut(False, String(), em2, ms_total, in_total, out_total, tries)
                return api_err.copy()
            if tries >= 3:
                var empty = MetaOut(
                    False, String(), String("no text in response"), ms_total, in_total, out_total, tries
                )
                return empty.copy()
        except:
            var badj = MetaOut(False, String(), String("bad response json"), ms_total, 0, 0, tries)
            return badj.copy()
