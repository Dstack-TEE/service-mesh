#!/usr/bin/env python3
"""Run bounded TLC checks, reachability witnesses, and counterexample controls."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
VERSION = "1.7.4"
JAR_SHA256 = "936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
JAR_URL = f"https://github.com/tlaplus/tlaplus/releases/download/v{VERSION}/tla2tools.jar"

# A counterexample is successful ONLY for the specified TLC exit code and
# property. Syntax errors, crashes, timeouts and unrelated violations fail.
CHECKS = [
    ("snapshots", "SnapshotStore", "SnapshotStore", "verified", None),
    ("snapshots", "SnapshotStore", "Unordered", "control", "BrokerOrdering"),
    ("snapshots", "SnapshotStore", "ClientUnordered", "control", "ClientOrdering"),
    ("snapshots", "SnapshotStore", "IgnoreOwnClock", "control", "PublicationFreshness"),
    ("snapshots", "SnapshotStore", "Reachable", "witness", "NoAcceptance"),
    ("handshake", "OfferAnswer", "OfferAnswer", "verified", None),
    ("handshake", "OfferAnswer", "MoreRetries", "verified", None),
    ("handshake", "OfferAnswer", "Unbound", "control", "AnswerBinding"),
    ("handshake", "OfferAnswer", "Unfair", "temporal-control", "EventuallyConnected"),
    ("handshake", "OfferAnswer", "Reachable", "witness", "NeverConnected"),
    ("attempts", "AttemptOwnership", "AttemptOwnership", "verified", None),
    ("attempts", "AttemptOwnership", "UnguardedICE", "control", "AttemptIsolation"),
    ("attempts", "AttemptOwnership", "UnguardedTimer", "control", "AttemptIsolation"),
    ("candidates", "CandidateReplay", "CandidateReplay", "verified", None),
    ("candidates", "CandidateReplay", "OldLocalCallback", "control", "LocalAuthIsolation"),
    ("candidates", "CandidateReplay", "RetargetedDelivery", "control", "CapturedAgentIsolation"),
    ("candidates", "CandidateReplay", "MissingReplay", "control", "ReplayCoverage"),
    ("candidates", "CandidateReplay", "Reachable", "witness", "NoSuccessfulReplay"),
    ("admission", "Admission", "Admission", "verified", None),
    ("admission", "Admission", "Replay", "control", "AtMostOneGrant"),
    ("admission", "Admission", "MissingKMS", "control", "AllChecksRequired"),
    ("admission", "Admission", "MissingEvidence", "control", "AllChecksRequired"),
    ("admission", "Admission", "MissingReportData", "control", "AllChecksRequired"),
    ("admission", "Admission", "MissingOSImage", "control", "AllChecksRequired"),
    ("admission", "Admission", "MissingWorkload", "control", "AllChecksRequired"),
    ("admission", "Admission", "Reachable", "witness", "NoGrants"),
    ("recovery", "RendezvousRecovery", "RecoverySafety", "prefix", None),
    ("recovery", "RendezvousRecovery", "EstablishedSafety", "prefix", None),
    ("recovery", "RendezvousRecovery", "Unbound", "control", "AnswerBinding"),
    ("recovery", "RendezvousRecovery", "OldRequestReachable", "witness", "NoOldRequests"),
    ("recovery", "RendezvousRecovery", "OldResponseReachable", "witness", "NoOldResponses"),
    ("lifetime", "CandidateLifetime", "DeferredFresh", "verified", None),
    ("lifetime", "CandidateLifetime", "EagerExpired", "control", "AttemptWorks"),
    ("lifetime", "CandidateLifetime", "DeferredExpired", "control", "AttemptWorks"),
    ("lifetime", "CandidateLifetime", "Reachable", "witness", "NoConnection"),
]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tool_jar():
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    jar = Path(os.environ.get(
        "TLA2TOOLS_JAR", cache / "dstack-service-mesh" / "tla2tools" / VERSION / "tla2tools.jar"
    )).expanduser().resolve()
    if not jar.exists():
        if "TLA2TOOLS_JAR" in os.environ:
            raise RuntimeError(f"TLA2TOOLS_JAR does not exist: {jar}")
        jar.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=jar.parent) as staging:
            download = Path(staging) / "tla2tools.jar"
            print(f"Downloading pinned TLA+ tools {VERSION}", flush=True)
            subprocess.run([
                "curl", "--fail", "--location", "--silent", "--show-error",
                "--max-time", "60", "--output", str(download), JAR_URL,
            ], check=True, timeout=65)
            if sha256(download) != JAR_SHA256:
                raise RuntimeError("Downloaded TLA+ tools checksum does not match the pin")
            download.replace(jar)
    if sha256(jar) != JAR_SHA256:
        raise RuntimeError(f"TLA+ tools checksum does not match the pin: {jar}")
    return jar


def run_check(check, jar, logs, timeout):
    family, module, config, kind, invariant = check
    name = f"{family}/{config}"
    log = logs / f"{family}-{config}.log"
    with tempfile.TemporaryDirectory(prefix="mesh-tlc-") as work:
        # TLC can emit trace modules next to the specification. Run isolated
        # copies so even failing/parallel invocations leave sources untouched.
        work = Path(work)
        for source in (ROOT / family).glob("*.tla"):
            shutil.copy2(source, work / source.name)
        shutil.copy2(ROOT / family / f"{config}.cfg", work)
        cmd = [
            "java", "-XX:+UseParallelGC", "-Xmx1g", "-cp", str(jar),
            "tlc2.TLC", "-workers", "1", "-seed", "1", "-fp", "0",
            "-metadir", str(work / "states"), "-config", f"{config}.cfg", f"{module}.tla",
        ]
        try:
            proc = subprocess.run(
                cmd, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, timeout=timeout, check=False,
            )
            output, returncode = proc.stdout, proc.returncode
        except subprocess.TimeoutExpired as exc:
            output = (exc.stdout or b"").decode() if isinstance(exc.stdout, bytes) else (exc.stdout or "")
            output += f"\nRunner timeout after {timeout} seconds.\n"
            returncode = None
    log.write_text(output)
    if kind in {"verified", "prefix"}:
        matched = returncode == 0 and "Model checking completed. No error has been found." in output
    elif kind == "temporal-control":
        matched = returncode == 13 and "Temporal properties were violated" in output
    else:
        matched = returncode == 12 and f"Invariant {invariant} is violated." in output
    label = {
        "verified": "VERIFIED MODEL",
        "prefix": "BOUNDED SAFETY PREFIXES (NO LIVENESS CLAIM)",
        "control": "COUNTEREXAMPLE CONTROL",
        "temporal-control": "COUNTEREXAMPLE CONTROL",
        "witness": "REACHABILITY WITNESS",
    }[kind]
    print(f"{'OK' if matched else 'FAIL'} {name}: {label}", flush=True)
    if not matched:
        print(output, file=sys.stderr)
    counts = re.findall(r"([\d,]+) states generated, ([\d,]+) distinct states found", output)
    result = {
        "check": name, "kind": kind, "expectation_met": matched,
        "exit_code": returncode, "expected_violation": invariant,
        "module": f"{family}/{module}.tla", "config": f"{family}/{config}.cfg",
        "module_sha256": sha256(ROOT / family / f"{module}.tla"),
        "config_sha256": sha256(ROOT / family / f"{config}.cfg"),
        "log": str(log.relative_to(logs)),
    }
    if counts:
        result["generated_states"], result["distinct_states"] = (
            int(n.replace(",", "")) for n in counts[-1]
        )
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", choices=sorted({c[0] for c in CHECKS}))
    parser.add_argument("--logs", type=Path, default=REPO / ".local" / "protocol-checks")
    parser.add_argument("--report", type=Path, help="also write a machine-readable verification report")
    parser.add_argument("--timeout", type=int, default=120, help="seconds allowed per exhaustive check")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    configured = {ROOT / c[0] / f"{c[2]}.cfg" for c in CHECKS}
    actual = set(ROOT.glob("*/*.cfg"))
    if configured != actual or len(configured) != len(CHECKS):
        raise RuntimeError("TLC configuration files and the check inventory differ")
    if not shutil.which("java"):
        raise RuntimeError("Java is required; install a JRE (tested with Java 17)")
    jar = tool_jar()
    logs = args.logs.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    selected = [c for c in CHECKS if args.only is None or c[0] == args.only]
    # Sequential checks keep peak memory bounded and logs unambiguous.
    results = [run_check(c, jar, logs, args.timeout) for c in selected]
    report = {
        "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "Exhaustive finite model checking, not a Go implementation proof",
        "tool": {"release": VERSION, "jar_sha256": JAR_SHA256},
        "implementation_sha256": {
            str(path.relative_to(REPO)): sha256(path) for path in [
                REPO / "components/mesh-conn/signaling.go",
                REPO / "components/mesh-conn/main.go",
                REPO / "components/admission-broker/main.go",
            ]
        },
        "checks": results,
    }
    (logs / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    failures = sum(not r["expectation_met"] for r in results)
    print(f"{len(results) - failures}/{len(results)} expectations met; "
          f"logs: {logs}")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"protocol check failed: {exc}", file=sys.stderr)
        sys.exit(1)
