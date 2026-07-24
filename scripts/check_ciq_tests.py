#!/usr/bin/env python3
"""Fail-closed parser for a Connect IQ unit-test run log (sim-run.log).

The simulator / monkeydo exit code CANNOT be trusted: the sim can exit 0 on a
broken run, a crashed harness, or when zero tests executed. So this parser
looks only at the printed results and PASSES only when it can positively prove
a clean run:

    * a summary line was printed,
    * its verdict is PASSED,
    * ran  > 0        (zero tests run == FAIL),
    * ran == passed,
    * failed == 0,
    * errors == 0.

Anything it cannot prove is a FAIL.

Connect IQ test-runner tail looks like:

    Ran 3 tests

    PASSED (passed=3, failed=0, errors=0)

Usage:  scripts/check_ciq_tests.py [sim-run.log]
"""

import re
import sys


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "sim-run.log"

    try:
        with open(path, "r", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print(f"FAIL: cannot read {path}: {exc}")
        sys.exit(1)

    if not text.strip():
        print(f"FAIL: {path} is empty - the run produced no output at all")
        sys.exit(1)

    ran_m = re.search(r"Ran\s+(\d+)\s+test", text)
    summary_m = re.search(
        r"\b(PASSED|FAILED|ERROR)\b\s*\(\s*passed\s*=\s*(\d+)\s*,\s*"
        r"failed\s*=\s*(\d+)\s*,\s*errors?\s*=\s*(\d+)\s*\)",
        text,
    )

    if summary_m is None:
        print(f"FAIL: no test-summary line found in {path} "
              "(run hung, crashed, or printed nothing parseable)")
        sys.exit(1)

    verdict = summary_m.group(1)
    passed = int(summary_m.group(2))
    failed = int(summary_m.group(3))
    errors = int(summary_m.group(4))

    if ran_m is None:
        print(f"FAIL: no 'Ran N tests' line found in {path}")
        sys.exit(1)
    ran = int(ran_m.group(1))

    problems = []
    if verdict != "PASSED":
        problems.append(f"verdict is {verdict}, not PASSED")
    if ran <= 0:
        problems.append("zero tests ran (a run with no tests is a failure)")
    if passed != ran:
        problems.append(f"passed ({passed}) != ran ({ran})")
    if failed != 0:
        problems.append(f"{failed} test(s) failed")
    if errors != 0:
        problems.append(f"{errors} test error(s)")

    print(f"summary: verdict={verdict} ran={ran} passed={passed} "
          f"failed={failed} errors={errors}")

    if problems:
        for p in problems:
            print(f"::error::run-tests: {p}")
        print("FAIL: " + "; ".join(problems))
        sys.exit(1)

    print(f"OK: {ran}/{ran} tests passed, 0 failures, 0 errors")
    sys.exit(0)


if __name__ == "__main__":
    main()
