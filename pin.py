#!/usr/bin/env python3
"""Local PIN unlock for the Omarchy Bitwarden widget.

The master password is encrypted with a key derived from the PIN (GnuPG
symmetric encryption, AES-256, high S2K count) and the ciphertext is kept in
the OS keyring. The PIN itself is never stored, and the decrypted master
password is used only to run `bw unlock`, whose session key is returned to the
widget.

Protocol: one JSON line on stdin, one JSON line on stdout. Secrets never
appear in argv.
"""

import base64
import json
import os
import re
import subprocess
import sys

SERVICE = "omarchy-bitwarden"
MIN_PIN = 6
MAX_PIN = 12
MAX_MASTER = 1024
MAX_EMAIL = 200
S2K_COUNT = "65011712"


def fail(code, detail=""):
    print(json.dumps({"ok": False, "error": code, "detail": str(detail)[:200]}))
    sys.exit(0)


def run(cmd, **kwargs):
    try:
        return subprocess.run(cmd, **kwargs)
    except subprocess.TimeoutExpired:
        fail("timeout")
    except Exception as exc:  # noqa: BLE001 - report, never crash the widget
        fail("helper-failed", str(exc))


def read_request():
    try:
        line = sys.stdin.readline(65536)
        data = json.loads(line or "{}")
    except Exception:
        fail("bad-request")
    if not isinstance(data, dict):
        fail("bad-request")
    return data


def valid_email(email):
    return (isinstance(email, str) and 0 < len(email) <= MAX_EMAIL
            and re.search(r"[\x00-\x1f\x7f]", email) is None)


def valid_pin(pin):
    return isinstance(pin, str) and re.fullmatch(
        r"[0-9]{%d,%d}" % (MIN_PIN, MAX_PIN), pin) is not None


def valid_master(master):
    return isinstance(master, str) and 0 < len(master) <= MAX_MASTER


def keyring_lookup(email):
    p = run(["secret-tool", "lookup", "service", SERVICE, "account", email],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    if p.returncode == 0:
        value = p.stdout.decode("utf-8", errors="replace").strip()
        return (True, value) if value else (False, None)
    detail = p.stderr.decode("utf-8", errors="replace").strip()
    if detail:
        fail("keyring-lookup-failed", detail)
    return (False, None)


def keyring_store(email, value):
    p = run(["secret-tool", "store", "--label", "Omarchy Bitwarden PIN",
             "service", SERVICE, "account", email],
            input=value.encode("utf-8"), stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=10)
    if p.returncode != 0:
        fail("keyring-store-failed", p.stderr.decode("utf-8", errors="replace"))


def keyring_clear(email):
    run(["secret-tool", "clear", "service", SERVICE, "account", email],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


def passphrase_pipe(pin):
    read_fd, write_fd = os.pipe()
    os.write(write_fd, pin.encode("utf-8"))
    os.close(write_fd)
    return read_fd


def gpg_encrypt(pin, plaintext):
    read_fd = passphrase_pipe(pin)
    cmd = [
        "gpg", "--batch", "--yes", "--pinentry-mode", "loopback",
        "--passphrase-file", "/dev/fd/%d" % read_fd,
        "--symmetric", "--cipher-algo", "AES256",
        "--s2k-mode", "3", "--s2k-digest-algo", "SHA512",
        "--s2k-count", S2K_COUNT, "--no-symkey-cache", "-o", "-",
    ]
    try:
        p = run(cmd, input=plaintext, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, pass_fds=(read_fd,), timeout=30)
    finally:
        os.close(read_fd)
    if p.returncode != 0:
        fail("encrypt-failed", p.stderr.decode("utf-8", errors="replace"))
    return base64.b64encode(p.stdout).decode("ascii")


def gpg_decrypt(pin, blob):
    try:
        data = base64.b64decode(blob.encode("ascii"), validate=True)
    except Exception:
        fail("bad-blob")
    read_fd = passphrase_pipe(pin)
    cmd = [
        "gpg", "--batch", "--yes", "--pinentry-mode", "loopback",
        "--passphrase-file", "/dev/fd/%d" % read_fd,
        "--decrypt", "--no-symkey-cache",
    ]
    try:
        p = run(cmd, input=data, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, pass_fds=(read_fd,), timeout=30)
    finally:
        os.close(read_fd)
    if p.returncode != 0:
        fail("wrong-pin")
    try:
        return p.stdout.decode("utf-8")
    except UnicodeDecodeError:
        fail("decrypt-failed")


def bw_unlock(master):
    env = os.environ.copy()
    env.pop("BW_SESSION", None)
    env["BW_PASSWORD"] = master
    p = run(["bw", "unlock", "--passwordenv", "BW_PASSWORD", "--raw"],
            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=30)
    if p.returncode != 0:
        fail("bw-failed", p.stderr.decode("utf-8", errors="replace"))
    lines = [line.strip() for line in p.stdout.decode("utf-8", errors="replace").splitlines()
             if line.strip()]
    key = lines[-1] if lines else ""
    if re.fullmatch(r"[A-Za-z0-9+/=_-]{16,512}", key) is None:
        fail("bad-session")
    return key


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    req = read_request()
    email = req.get("email", "")
    if not valid_email(email):
        fail("bad-email")

    if action == "status":
        found, _ = keyring_lookup(email)
        print(json.dumps({"ok": True, "enabled": found}))
        return

    if action == "clear":
        keyring_clear(email)
        print(json.dumps({"ok": True, "enabled": False}))
        return

    pin = req.get("pin", "")
    if not valid_pin(pin):
        fail("bad-pin")

    if action == "set":
        master = req.get("master", "")
        if not valid_master(master):
            fail("bad-master")
        blob = gpg_encrypt(pin, master.encode("utf-8"))
        keyring_store(email, blob)
        print(json.dumps({"ok": True, "enabled": True}))
        return

    if action == "get":
        found, blob = keyring_lookup(email)
        if not found:
            fail("not-configured")
        master = gpg_decrypt(pin, blob)
        session = bw_unlock(master)
        print(json.dumps({"ok": True, "session": session}))
        return

    fail("bad-action")


if __name__ == "__main__":
    main()
