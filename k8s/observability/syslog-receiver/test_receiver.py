#!/usr/bin/env python3
"""Self-check for the syslog receiver. Run: python3 test_receiver.py

Extracts receiver.py from the ConfigMap, runs it on a high port, and asserts the
two things that would silently break log ingestion: RFC3164 PRI decoding and the
sender allow-list.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))


def extract():
    cm = yaml.safe_load(open(os.path.join(HERE, "configmap.yaml")))
    path = os.path.join(tempfile.mkdtemp(), "receiver.py")
    open(path, "w").write(cm["data"]["receiver.py"])
    return path


def run(script, port, allowed, packets):
    proc = subprocess.Popen(
        [sys.executable, script],
        env={**os.environ, "SYSLOG_PORT": str(port), "ALLOWED_SENDERS": allowed},
        stdout=subprocess.PIPE, text=True,
    )
    try:
        time.sleep(1.5)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        for p in packets:
            sock.sendto(p, ("127.0.0.1", port))
        time.sleep(1.5)
    finally:
        proc.terminate()
    out = proc.communicate(timeout=5)[0]
    # first line is the startup banner
    return [json.loads(line) for line in out.strip().splitlines()[1:]]


def main():
    script = extract()

    got = run(script, 15140, "127.0.0.1", [
        b"<28>03-Aug-2026 19:42:20 %LINK-W-Down:  gi44",
        b"<190>03-Aug-2026 19:42:21 %LINK-I-Up:  gi44",
        b"no-pri-prefix",
    ])
    assert len(got) == 3, f"expected 3 accepted messages, got {len(got)}"
    assert got[0]["severity"] == "warning", got[0]
    assert "gi44" in got[0]["message"], got[0]
    assert got[1]["severity"] == "info", got[1]
    # malformed input must pass through rather than crash the receiver
    assert got[2]["severity"] is None, got[2]
    assert got[2]["message"] == "no-pri-prefix", got[2]

    blocked = run(script, 15141, "10.99.99.99", [b"<28>spoofed"])
    assert blocked == [], f"allow-list let a foreign sender through: {blocked}"

    print("ok — PRI decoding and sender allow-list both behave")
    return 0


if __name__ == "__main__":
    sys.exit(main())
