#!/usr/bin/env python3
"""Regression: /api/mahsanet/donate must validate the 'protocols' body field.

The endpoint validated count + prefix but passed 'protocols' from the request
body straight into DONATE_ONLY_PROTOCOLS -> " ".join() -> user-add.sh. A non-list
crashed the join (500) and stray values reached a shell env. This pins the
validation. Extracts validate_donate_protocols from admin/main.py without
importing the FastAPI app (same trick as admin-ip-whitelist-test.py).
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "admin", "main.py")
src = open(MAIN).read()
start = src.index("def validate_donate_protocols(")
end = src.index("\n\n\n", start)
ns = {"re": re}
exec(compile(src[start:end], MAIN, "exec"), ns)  # noqa: S102
validate = ns["validate_donate_protocols"]

fails = 0


def ok(cond, msg):
    global fails
    print(("  ok    " if cond else "  FAIL  ") + msg)
    if not cond:
        fails += 1


ok(validate(["reality", "hysteria2"]) == ["reality", "hysteria2"], "accepts a valid list")

for bad, label in [
    ("reality", "a bare string (not a list)"),
    ([], "an empty list"),
    (["reality; rm -rf /"], "a shell-ish value"),
    (["reality", 123], "a non-string element"),
    ([f"x{i}" for i in range(21)], "too many protocols"),
    (["Reality!"], "invalid characters"),
]:
    try:
        validate(bad)
        ok(False, f"rejects {label}")
    except ValueError:
        ok(True, f"rejects {label}")

print("\n" + ("FAILED" if fails else "PASSED"))
raise SystemExit(1 if fails else 0)
