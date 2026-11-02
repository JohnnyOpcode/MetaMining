"""Tests for metamining.endpoint: paths, extractors, models parse.

Live Meta calls run only when META_API_KEY (or MODEL_API_KEY) is set
and META_OFFLINE != 1.
"""

from std.os.env import getenv
from std.testing import assert_equal, assert_true

from metamining.endpoint import (
    MetaCfg,
    MetaOut,
    api_path,
    embed_base,
    embed_input,
    error_message,
    extract_text,
    meta_embed,
    meta_models,
    meta_respond,
    model_known,
    model_rates,
    parse_embeddings,
    parse_models,
    parse_usage,
)
from metamining.libc import (
    accept_conn,
    bind_listen,
    child_exit,
    close_fd,
    fork_child,
    poll_one,
    set_timeout,
    socket_port,
    tcp_recv_some,
    tcp_send_all,
    wait_child,
)


def test_api_path() raises:
    assert_equal(api_path("/v1", "responses"), "/v1/responses")
    assert_equal(api_path("/v1/", "models"), "/v1/models")
    assert_equal(api_path("/v1/responses", "responses"), "/v1/responses")
    assert_equal(api_path("/v1/responses", "models"), "/v1/models")
    assert_equal(api_path("", "models"), "/models")
    assert_equal(api_path("/v1", "embeddings"), "/v1/embeddings")
    assert_equal(api_path("/v1/responses", "embeddings"), "/v1/embeddings")
    print("api_path ok")


def test_extract() raises:
    var msg = String(
        '{"id":"r1","output":[{"type":"message","content":['
        '{"type":"output_text","text":"vein gold here"}]}]}'
    )
    assert_equal(extract_text(msg), "vein gold here")
    var mixed = String(
        '{"output":[{"type":"reasoning","content":['
        '{"type":"summary_text","text":"thinking..."}]},'
        '{"type":"message","content":['
        '{"type":"output_text","text":"answer one"},'
        '{"type":"output_text","text":"answer two"}]}]}'
    )
    assert_equal(extract_text(mixed), "answer one\n\nanswer two")
    var fallback = String('{"output":[{"type":"note","text":"loose"}]}')
    assert_equal(extract_text(fallback), "loose")
    var none = String('{"output":[{"type":"reasoning"}]}')
    assert_equal(extract_text(none), "")
    print("extract ok")


def test_models_parse() raises:
    var body = String('{"data":[{"id":"muse-spark"},{"id":"m2"}]}')
    var out = List[String]()
    assert_equal(parse_models(body, out), "")
    assert_equal(len(out), 2)
    assert_equal(out[0], "muse-spark")
    var bad = List[String]()
    assert_true(parse_models("{}", bad) != "")
    assert_equal(error_message('{"error":{"message":"bad key"}}'), "bad key")
    assert_equal(error_message('{"error":"flat"}'), "flat")
    assert_equal(error_message("nope"), "")
    print("models_parse ok")


def test_embed_parse() raises:
    var body = String(
        '{"data":[{"embedding":[0.5,-0.25,0.125]},'
        '{"embedding":[0.0,0.0,1.0]}]}'
    )
    var out = List[List[Float64]]()
    assert_equal(parse_embeddings(body, out), "")
    assert_equal(len(out), 2)
    assert_equal(len(out[0]), 3)
    assert_equal(out[0][0], 0.5)
    assert_equal(out[0][1], -0.25)
    assert_equal(out[1][2], 1.0)
    var bad = List[List[Float64]]()
    assert_true(parse_embeddings("{}", bad) != "")
    var bad2 = List[List[Float64]]()
    assert_true(parse_embeddings('{"data":[{"embedding":[]}]}', bad2) != "")
    var notexts = List[String]()
    var empty = List[List[Float64]]()
    var nocfg = MetaCfg("https://api.meta.ai/v1", "k", "m", "")
    assert_equal(meta_embed(nocfg, notexts, empty), "no embedding model configured")
    print("embed_parse ok")


def test_usage() raises:
    var u = parse_usage('{"usage":{"input_tokens":120,"output_tokens":45}}')
    assert_equal(u.inp, 120)
    assert_equal(u.out, 45)
    var u2 = parse_usage('{"output":[]}')
    assert_equal(u2.inp, 0)
    assert_equal(u2.out, 0)
    var u3 = parse_usage("not json")
    assert_equal(u3.inp, 0)
    var u4 = parse_usage('{"usage":{"input_tokens":7}}')
    assert_equal(u4.inp, 7)
    assert_equal(u4.out, 0)
    var u5 = parse_usage('{"usage":{"input_tokens":1e999,"output_tokens":45}}')
    assert_equal(u5.inp, 0)
    assert_equal(u5.out, 45)
    var u6 = parse_usage('{"usage":{"input_tokens":7,"output_tokens":1e999}}')
    assert_equal(u6.inp, 7)
    assert_equal(u6.out, 0)
    print("usage ok")


def test_rates() raises:
    var s = model_rates("muse-spark-1.3")
    assert_equal(s.inp, 1.25)
    assert_equal(s.out, 4.25)
    var c = model_rates("muse-spark-1.2-contributor")
    assert_equal(c.inp, 0.10)
    assert_equal(c.out, 0.20)
    var w = model_rates("muse-wonder-1.0")
    assert_equal(w.inp, 4.0)
    assert_equal(w.out, 20.0)
    var u = model_rates("mystery-model")
    assert_true(u.inp < 0.0)
    assert_true(u.out < 0.0)
    print("rates ok")


def test_model_known() raises:
    var ids = List[String]()
    ids.append("muse-spark-1.3")
    ids.append("muse-spark-1.3-contributor")
    assert_true(model_known(ids, "muse-spark-1.3"))
    assert_true(model_known(ids, "  muse-spark-1.3-contributor "))
    assert_true(model_known(ids, "MUSE-SPARK-1.3"))
    assert_true(not model_known(ids, "meta-contributor-1.2"))
    assert_true(not model_known(ids, "muse-spark"))
    assert_true(not model_known(ids, ""))
    assert_true(not model_known(ids, "   "))
    var empty = List[String]()
    assert_true(not model_known(empty, "muse-spark-1.3"))
    print("model_known ok")


def test_live_meta() raises:
    var key = getenv("META_API_KEY", "")
    if key == "":
        key = getenv("MODEL_API_KEY", "")
    if key == "" or getenv("META_OFFLINE", "") == "1":
        print("live_meta SKIPPED (needs META_API_KEY, no META_OFFLINE)")
        return
    var cfg = MetaCfg(
        "https://api.meta.ai/v1", key, "muse-spark", getenv("META_EMBED_MODEL", "")
    )
    var ids = List[String]()
    var err = meta_models(cfg, ids)
    print("live models err=[" + err + "] count=" + String(len(ids)))
    var r = meta_respond(cfg, "Reply with exactly: OK", "ping", 0.0)
    print(
        "live respond ok="
        + String(r.ok)
        + " text=["
        + r.text
        + "] err=["
        + r.err
        + "] ms="
        + String(r.ms)
        + " tok="
        + String(r.in_tok)
        + "/"
        + String(r.out_tok)
    )
    if cfg.embed_model != "":
        var texts = List[String]()
        texts.append("latent space mining vein")
        texts.append("a second probe sentence")
        var vecs = List[List[Float64]]()
        var eerr = meta_embed(cfg, texts, vecs)
        var dim = 0
        if len(vecs) > 0:
            dim = len(vecs[0])
        print(
            "live embed err=["
            + eerr
            + "] n="
            + String(len(vecs))
            + " dim="
            + String(dim)
        )


def retry_stub(srv: Int, b0: String, b1: String, b2: String):
    var bodies = List[String]()
    bodies.append(b0)
    bodies.append(b1)
    bodies.append(b2)
    for i in range(3):
        if poll_one(srv, 15000) != 1:
            child_exit(3)
        var conn = accept_conn(srv)
        _ = set_timeout(conn, 10)
        var req = String()
        for _ in range(8):
            req += tcp_recv_some(conn, 4096)
            if req.find("POST /responses") >= 0:
                break
        var resp = (
            String(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
            )
            + String(bodies[i].byte_length())
            + "\r\nConnection: close\r\n\r\n"
            + bodies[i]
        )
        _ = tcp_send_all(conn, resp)
        _ = close_fd(conn)
    _ = close_fd(srv)
    child_exit(0)


def run_retry_case(b0: String, b1: String, b2: String) raises -> MetaOut:
    var srv = bind_listen("127.0.0.1", 0)
    assert_true(srv >= 0)
    var port = socket_port(srv)
    var pid = fork_child()
    assert_true(pid >= 0)
    if pid == 0:
        retry_stub(srv, b0, b1, b2)
        child_exit(0)
    _ = close_fd(srv)
    var cfg = MetaCfg("http://127.0.0.1:" + String(port), "k", "m", "")
    var r = meta_respond(cfg, "sys", "hi", 0.5)
    var w = wait_child(pid, False)
    assert_equal(w.pid, pid)
    assert_equal(w.status, 0)
    return r.copy()


def test_retry() raises:
    var thin = String(
        '{"id":"r0","status":"incomplete","output":[{"type":"reasoning"}],'
        '"usage":{"input_tokens":10,"output_tokens":100}}'
    )
    var good = String(
        '{"id":"r1","status":"completed","output":[{"type":"message",'
        '"content":[{"type":"output_text","text":"retry gold"}]}],'
        '"usage":{"input_tokens":10,"output_tokens":120}}'
    )
    var r1 = run_retry_case(thin, thin, good)
    assert_true(r1.ok)
    assert_equal(r1.text, "retry gold")
    assert_equal(r1.tries, 3)
    assert_equal(r1.in_tok, 30)
    assert_equal(r1.out_tok, 320)
    var r2 = run_retry_case(thin, thin, thin)
    assert_true(not r2.ok)
    assert_equal(r2.err, "no text in response")
    assert_equal(r2.tries, 3)
    assert_equal(r2.in_tok, 30)
    assert_equal(r2.out_tok, 300)
    print("retry ok")


def status_stub(srv: Int, s0: Int, b0: String, s1: Int, b1: String, n: Int):
    var codes = List[Int]()
    codes.append(s0)
    codes.append(s1)
    var bodies = List[String]()
    bodies.append(b0)
    bodies.append(b1)
    for i in range(n):
        if poll_one(srv, 15000) != 1:
            child_exit(3)
        var conn = accept_conn(srv)
        _ = set_timeout(conn, 10)
        var req = String()
        for _ in range(8):
            req += tcp_recv_some(conn, 4096)
            if req.find("POST /responses") >= 0:
                break
        var st = codes[i]
        var label = String("OK")
        if st == 429:
            label = String("Too Many Requests")
        elif st == 500:
            label = String("Internal Server Error")
        elif st == 400:
            label = String("Bad Request")
        elif st == 401:
            label = String("Unauthorized")
        var resp = (
            String("HTTP/1.1 ")
            + String(st)
            + " "
            + label
            + "\r\nContent-Type: application/json\r\nContent-Length: "
            + String(bodies[i].byte_length())
            + "\r\nConnection: close\r\n\r\n"
            + bodies[i]
        )
        _ = tcp_send_all(conn, resp)
        _ = close_fd(conn)
    _ = close_fd(srv)
    child_exit(0)


def run_status_case(s0: Int, b0: String, s1: Int, b1: String, n: Int) raises -> MetaOut:
    var srv = bind_listen("127.0.0.1", 0)
    assert_true(srv >= 0)
    var port = socket_port(srv)
    var pid = fork_child()
    assert_true(pid >= 0)
    if pid == 0:
        status_stub(srv, s0, b0, s1, b1, n)
        child_exit(0)
    _ = close_fd(srv)
    var cfg = MetaCfg("http://127.0.0.1:" + String(port), "k", "m", "")
    var r = meta_respond(cfg, "sys", "hi", 0.5)
    var w = wait_child(pid, False)
    assert_equal(w.pid, pid)
    assert_equal(w.status, 0)
    return r.copy()


def test_retry_status() raises:
    var good = String(
        '{"id":"r1","status":"completed","output":[{"type":"message",'
        '"content":[{"type":"output_text","text":"retry gold"}]}],'
        '"usage":{"input_tokens":10,"output_tokens":120}}'
    )
    var rl = String('{"error":{"message":"rate limited"}}')
    var r429 = run_status_case(429, rl, 200, good, 2)
    assert_true(r429.ok)
    assert_equal(r429.text, "retry gold")
    assert_equal(r429.tries, 2)
    assert_equal(r429.in_tok, 10)
    assert_equal(r429.out_tok, 120)
    var flaky = String('{"error":{"message":"flaky backend"}}')
    var r500 = run_status_case(500, flaky, 200, good, 2)
    assert_true(r500.ok)
    assert_equal(r500.text, "retry gold")
    assert_equal(r500.tries, 2)
    var bad = String('{"error":{"message":"bad request"}}')
    var r400 = run_status_case(400, bad, 200, good, 1)
    assert_true(not r400.ok)
    assert_equal(r400.err, "bad request")
    assert_equal(r400.tries, 1)
    var r401 = run_status_case(401, bad, 200, good, 1)
    assert_true(not r401.ok)
    assert_equal(r401.tries, 1)
    assert_true(r401.err.find("unauthorized") >= 0)
    print("retry status ok")


def test_embed_base() raises:
    var main = MetaCfg("https://api.meta.ai/v1", "k", "m", "e")
    assert_equal(embed_base(main), "https://api.meta.ai/v1")
    var byo = MetaCfg(
        "https://api.meta.ai/v1", "k", "m", "e", "http://127.0.0.1:8080/v1"
    )
    assert_equal(embed_base(byo), "http://127.0.0.1:8080/v1")
    assert_equal(byo.embed_doc_prefix, "")
    assert_equal(byo.embed_query_prefix, "")
    var full = MetaCfg("https://api.meta.ai/v1", "", "m", "e", "", "dp:", "qp:")
    assert_equal(embed_input(full.embed_doc_prefix, "doc"), "dp:doc")
    assert_equal(embed_input(full.embed_query_prefix, "q"), "qp:q")
    assert_equal(embed_input("", "plain"), "plain")
    print("embed_base ok")


def main() raises:
    test_api_path()
    test_extract()
    test_models_parse()
    test_embed_parse()
    test_embed_base()
    test_usage()
    test_rates()
    test_model_known()
    test_retry()
    test_retry_status()
    test_live_meta()
    print("ALL ENDPOINT TESTS PASSED")
