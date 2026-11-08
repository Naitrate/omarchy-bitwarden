#!/usr/bin/env python3
"""Regression checks for the PIN helper's validation and crypto round-trip."""

import importlib.util
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bw_pin", ROOT / "pin.py")
pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pin)

assert pin.valid_pin("123456")
assert pin.valid_pin("123456789012")
assert not pin.valid_pin("12345")
assert not pin.valid_pin("1234567890123")
assert not pin.valid_pin("abcdef")
assert not pin.valid_pin("12345\n")

assert pin.valid_email("person@example.com")
assert not pin.valid_email("")
assert not pin.valid_email("a\nb")
assert not pin.valid_email("x" * 201)

assert pin.valid_master("correct horse battery staple")
assert not pin.valid_master("")
assert not pin.valid_master("x" * 1025)

blob = pin.gpg_encrypt("123456", b"master-password-value")
assert pin.gpg_decrypt("123456", blob) == "master-password-value"

print("pin.py: ok")
