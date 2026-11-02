"""Tests for metamining.libc: parse, loopback TCP, pipe+fork."""

from std.testing import assert_equal, assert_true

from metamining.libc import (
    accept_conn,
    bind_listen,
    child_exit,
    close_fd,
    dir_list,
    dir_make,
    file_append_all,
    file_read_all,
    file_remove,
    file_stat,
    file_write_all,
    fork_child,
    format_mtime,
    format_stamp,
    mono_ms,
    msleep,
    parse_ipv4,
    pipe_fds,
    pipe_read_some,
    pipe_write_all,
    poll_one,
    socket_port,
    tcp_connect,
    tcp_connect_timeout,
    tcp_recv_some,
    tcp_send_all,
    time_now,
    wait_child,
)


def test_parse_ipv4() raises:
    var lo = parse_ipv4("localhost")
    assert_true(lo.ok)
    assert_equal(Int(lo.b0), 127)
    assert_equal(Int(lo.b3), 1)
    var q = parse_ipv4("10.20.30.40")
    assert_true(q.ok)
    assert_equal(Int(q.b0), 10)
    assert_equal(Int(q.b1), 20)
    assert_equal(Int(q.b2), 30)
    assert_equal(Int(q.b3), 40)
    assert_true(not parse_ipv4("10.20.30").ok)
    assert_true(not parse_ipv4("10.20.30.999").ok)
    assert_true(not parse_ipv4("example.com").ok)
    assert_true(not parse_ipv4("").ok)
    print("parse_ipv4 ok")


def test_loopback() raises:
    var srv = bind_listen("127.0.0.1", 0)
    assert_true(srv >= 0)
    var port = socket_port(srv)
    assert_true(port > 0)
    assert_equal(poll_one(srv, 20), 0)
    var cli = tcp_connect("127.0.0.1", port)
    assert_true(cli >= 0)
    assert_equal(poll_one(srv, 2000), 1)
    var conn = accept_conn(srv)
    assert_true(conn >= 0)
    var msg = String("claim-stake-42")
    assert_equal(tcp_send_all(cli, msg), msg.byte_length())
    assert_equal(poll_one(conn, 2000), 1)
    assert_equal(tcp_recv_some(conn, 64), msg)
    _ = close_fd(conn)
    _ = close_fd(cli)
    _ = close_fd(srv)
    assert_equal(bind_listen("example.com", 80), -1)
    print("loopback ok")


def test_pipe_fork() raises:
    var pair = pipe_fds()
    assert_true(pair.ok)
    var pid = fork_child()
    assert_true(pid >= 0)
    if pid == 0:
        _ = close_fd(pair.read_fd)
        _ = pipe_write_all(pair.write_fd, "ping")
        _ = close_fd(pair.write_fd)
        child_exit(0)
    _ = close_fd(pair.write_fd)
    assert_equal(poll_one(pair.read_fd, 2000), 1)
    assert_equal(pipe_read_some(pair.read_fd, 16), "ping")
    _ = close_fd(pair.read_fd)
    msleep(50)
    var w = wait_child(pid, False)
    assert_equal(w.pid, pid)
    print("pipe_fork ok")


def test_mono() raises:
    var t0 = mono_ms()
    assert_true(t0 > 0)
    msleep(50)
    var dt = mono_ms() - t0
    assert_true(dt >= 40 and dt < 5000)
    print("mono ok")


def _has(names: List[String], want: String) -> Bool:
    for i in range(len(names)):
        if names[i] == want:
            return True
    return False


def _is_digits(s: String) -> Bool:
    if s.byte_length() == 0:
        return False
    for b in s.bytes():
        var v = Int(b)
        if v < 48 or v > 57:
            return False
    return True


def test_dir_make() raises:
    var d = String("/tmp/mm_libc_d")
    assert_equal(dir_make(d), 0)
    assert_equal(dir_make(d), 0)  # EEXIST ok
    assert_equal(dir_make(d + "/sub"), 0)
    assert_equal(dir_make(d + "/sub"), 0)
    assert_equal(dir_make("/tmp/mm_libc_nope_xyz/sub"), -1)  # ENOENT
    print("dir_make ok")


def test_file_roundtrip() raises:
    var d = String("/tmp/mm_libc_t")
    assert_equal(dir_make(d), 0)
    var p = d + "/rt.txt"
    var data = String("roundtrip-bytes-123")
    assert_equal(file_write_all(p, data), data.byte_length())
    assert_equal(file_read_all(p), data)
    assert_equal(file_read_all("/tmp/mm_libc_nope_xyz.txt"), String())
    print("file_roundtrip ok")


def test_dir_list() raises:
    var d = String("/tmp/mm_libc_t")
    assert_equal(dir_make(d), 0)
    assert_true(file_write_all(d + "/a.txt", "a") > 0)
    assert_true(file_write_all(d + "/b.txt", "bb") > 0)
    var names = dir_list(d)
    assert_true(_has(names, "a.txt"))
    assert_true(_has(names, "b.txt"))
    assert_true(not _has(names, "."))
    assert_true(not _has(names, ".."))
    assert_equal(len(dir_list("/tmp/mm_libc_nope_xyz")), 0)
    print("dir_list ok")


def test_file_stat() raises:
    var d = String("/tmp/mm_libc_t")
    assert_equal(dir_make(d), 0)
    var p = d + "/sized.txt"
    var data = String("0123456789")
    assert_equal(file_write_all(p, data), 10)
    var st = file_stat(p)
    assert_equal(st[0], 10)
    assert_true(st[1] > 0)
    var missing = file_stat("/tmp/mm_libc_nope_xyz.txt")
    assert_equal(missing[0], -1)
    assert_equal(missing[1], -1)
    print("file_stat ok")


def test_time_fmt() raises:
    var now = time_now()
    assert_true(now > 1600000000)  # past 2020-09-13
    var stamp = format_stamp(now)
    assert_equal(stamp.byte_length(), 15)
    assert_true(_is_digits(String(stamp[byte=0:8])))
    assert_equal(String(stamp[byte=8:9]), "_")
    assert_true(_is_digits(String(stamp[byte=9:15])))
    var mt = format_mtime(now)
    assert_equal(mt.byte_length(), 16)
    assert_equal(String(mt[byte=4:5]), "-")
    assert_equal(String(mt[byte=7:8]), "-")
    assert_equal(String(mt[byte=10:11]), " ")
    assert_equal(String(mt[byte=13:14]), ":")
    assert_true(_is_digits(String(mt[byte=0:4])))
    assert_true(_is_digits(String(mt[byte=14:16])))
    # Known epoch: 0 -> 19700101_000000 in UTC; shape must hold anyway.
    assert_equal(format_stamp(0).byte_length(), 15)
    print("time_fmt ok")


def test_file_append() raises:
    var d = String("/tmp/mm_libc_t")
    assert_equal(dir_make(d), 0)
    var p = d + "/app.txt"
    _ = file_remove(p)
    assert_equal(file_append_all(p, "a"), 1)
    assert_equal(file_append_all(p, "bc"), 2)
    assert_equal(file_read_all(p), "abc")
    print("file_append ok")


def test_file_remove() raises:
    var d = String("/tmp/mm_libc_t")
    assert_equal(dir_make(d), 0)
    var p = d + "/gone.txt"
    assert_true(file_write_all(p, "bye") > 0)
    assert_equal(file_remove(p), 0)
    assert_equal(file_stat(p)[0], -1)
    assert_equal(file_remove(p), -1)
    print("file_remove ok")


def test_connect_failures() raises:
    # Refused loopback port fails immediately.
    var srv = bind_listen("127.0.0.1", 0)
    assert_true(srv >= 0)
    var port = socket_port(srv)
    _ = close_fd(srv)
    var t0 = mono_ms()
    assert_equal(tcp_connect("127.0.0.1", port), -1)
    assert_true(mono_ms() - t0 < 5000)
    # Hermetic blackhole: fill the accept queue (backlog 32) and never
    # accept. Short-timeout probes complete while there is room; the first
    # probe that times out proves the queue is full. The next full-timeout
    # connect must then hang to ~our timeout and fail - not the kernel's
    # minutes-long TCP timeout (a stuck expedition otherwise). No
    # off-loopback IP is used: sandboxes may intercept those.
    var bh = bind_listen("127.0.0.1", 0)
    assert_true(bh >= 0)
    var bhport = socket_port(bh)
    var held = List[Int]()
    var full = False
    for _ in range(96):
        var h = tcp_connect_timeout("127.0.0.1", bhport, 500)
        if h < 0:
            # Retry once with a longer probe: only a repeated timeout
            # proves a full queue rather than a slow scheduler.
            var h2 = tcp_connect_timeout("127.0.0.1", bhport, 2000)
            if h2 < 0:
                full = True
            else:
                held.append(h2)
                continue
            break
        held.append(h)
    assert_true(full)
    assert_true(len(held) >= 20)
    t0 = mono_ms()
    assert_equal(tcp_connect("127.0.0.1", bhport), -1)
    var dt = mono_ms() - t0
    for i in range(len(held)):
        _ = close_fd(held[i])
    _ = close_fd(bh)
    assert_true(dt >= 9000 and dt < 30000)
    assert_equal(tcp_connect("example.com", 443), -1)
    print("connect_failures ok (" + String(dt) + "ms blackhole)")


def main() raises:
    test_parse_ipv4()
    test_loopback()
    test_connect_failures()
    test_pipe_fork()
    test_mono()
    test_dir_make()
    test_file_roundtrip()
    test_dir_list()
    test_file_stat()
    test_file_remove()
    test_file_append()
    test_time_fmt()
    print("ALL LIBC TESTS PASSED")
