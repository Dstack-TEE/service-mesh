#!/usr/bin/env python3
"""Check symbolic security proofs, attack witnesses, and negative controls."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import tarfile
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
TOOLS = {
    "tamarin": {
        "version": "1.12.0",
        "url": "https://github.com/tamarin-prover/tamarin-prover/releases/download/1.12.0/"
               "tamarin-prover-1.12.0-linux64-ubuntu.tar.gz",
        "sha256": "201be06f469e47cff554df6ca93db8366fc2c69d70c61fcbd1370a1074b469c6",
        "binary": "tamarin-prover",
    },
    "maude": {
        "version": "3.5.1",
        "url": "https://github.com/maude-lang/Maude/releases/download/Maude3.5.1/"
               "Maude-3.5.1-linux-x86_64.zip",
        "sha256": "72ed1ca87e3b3d0dfc6ee1436baf154bf04c45ff97d521bec040c5e8dfc8f92c",
        "binary": "maude",
    },
}

ADMISSION = "protocol/admission/AdmissionSecurity.spthy"
SIGNALING = "protocol/snapshots/SignalingAuth.spthy"
# Baselines require every lemma to complete. Controls select exact properties;
# unrelated unselected lemmas are not counted as results.
CHECKS = [
    ("signaling-auth", SIGNALING, None, {
        "record_authentic_unless_root_exposed": "verified",
        "access_token_does_not_reveal_record_key": "verified",
        "publication_reachable": "verified",
        "individual_authentication_despite_other_member_compromise": "falsified",
    }),
    ("admission", ADMISSION, None, {
        "platform_key_secret": "verified",
        "grant_has_matching_evidence": "verified",
        "grant_requires_broker_local_challenge": "verified",
        "shared_platform_root_reachable": "verified",
        "grant_matches_policy": "verified",
        "nonce_single_grant": "verified",
        "honest_token_secret": "verified",
        "honest_response_authentic": "verified",
        "honest_admission_reachable": "verified",
        "claimed_instance_is_attested_instance": "falsified",
    }),
    ("replayed-nonce", ADMISSION, "REPLAY_NONCE", {"nonce_single_grant": "falsified"}),
    ("unbound-evidence", ADMISSION, "OMIT_REPORT_BINDING", {
        "grant_has_matching_evidence": "falsified",
    }),
    ("unmatched-peer", ADMISSION, "OMIT_PEER_POLICY", {"grant_matches_policy": "falsified"}),
    ("public-admission-channel", ADMISSION, "PUBLIC_CHANNEL", {
        "honest_token_secret": "falsified",
        "issued_token_disclosure_reachable": "verified",
    }),
]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def toolchain(name):
    spec = TOOLS[name]
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    cache = cache / "dstack-service-mesh" / name / spec["version"]
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / spec["url"].rsplit("/", 1)[1]
    if not archive.exists():
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            download = Path(temporary) / archive.name
            print(f"Downloading pinned {name} {spec['version']}", flush=True)
            subprocess.run([
                "curl", "--fail", "--location", "--silent", "--show-error",
                "--max-time", "90", "--output", str(download), spec["url"],
            ], check=True, timeout=100)
            if digest(download) != spec["sha256"]:
                raise RuntimeError(f"{name} download checksum mismatch")
            download.replace(archive)
    if digest(archive) != spec["sha256"]:
        raise RuntimeError(f"{name} archive checksum mismatch: {archive}")
    extracted = cache / "bin"
    marker = extracted / ".verified-archive-sha256"
    if not marker.exists() or marker.read_text().strip() != spec["sha256"]:
        extracted.mkdir(exist_ok=True)
        if name == "tamarin":
            with tarfile.open(archive) as contents:
                contents.extractall(extracted, filter="data")
        else:
            with zipfile.ZipFile(archive) as contents:
                for member in contents.namelist():
                    if Path(member).is_absolute() or ".." in Path(member).parts:
                        raise RuntimeError("Unsafe archive member")
                contents.extractall(extracted)
        (extracted / spec["binary"]).chmod(0o755)
        marker.write_text(spec["sha256"] + "\n")
    return (extracted / spec["binary"]).resolve()


def run_check(check, tamarin, maude, logs, timeout):
    name, source, define, expected = check
    proof = logs / f"{name}.spthy"
    traces = logs / f"{name}-traces.json"
    for artifact in (proof, traces):
        artifact.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="mesh-security-") as temporary:
        copied = Path(temporary) / Path(source).name
        copied.write_bytes((REPO / source).read_bytes())
        source_hash = digest(copied)
        command = [
            str(tamarin), "+RTS", "-N2", "-RTS", f"--with-maude={maude}",
            "--derivcheck-timeout=0", "--quit-on-warning", "--stop-on-trace=DFS",
            f"--output={proof}", f"--output-json={traces}",
        ]
        if define:
            command += [f"-D={define}"] + [f"--prove={lemma}" for lemma in expected]
        else:
            command += ["--prove"]
        command += [str(copied)]
        process = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, start_new_session=True,
        )
        try:
            output, _ = process.communicate(timeout=timeout)
            exit_code = process.returncode
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
            output += f"\nRunner timeout after {timeout} seconds.\n"
            exit_code = None
    (logs / f"{name}.log").write_text(output)
    summary = output.split("summary of summaries:")[-1]
    results = {}
    pattern = r"^\s+(\w+) \((all-traces|exists-trace)\): (verified|falsified|analysis incomplete)"
    for lemma, quantifier, result in re.findall(pattern, summary, re.M):
        if not define or lemma in expected:
            results[lemma] = {"quantifier": quantifier, "result": result}
    artifacts = {p.name: digest(p) for p in (proof, traces) if p.exists()}
    passed = (exit_code == 0 and "summary of summaries:" in output
              and len(artifacts) == 2 and set(results) == set(expected)
              and all(results[k]["result"] == v for k, v in expected.items()))
    print(f"{'PASS' if passed else 'FAIL'} {name}", flush=True)
    if not passed:
        print(output, file=sys.stderr)
    return {
        "check": name, "source": source, "source_sha256": source_hash,
        "define": define, "expectation_met": passed, "exit_code": exit_code,
        "expected_results": expected, "results": results,
        "log": f"{name}.log", "proof": f"{name}.spthy", "traces": f"{name}-traces.json",
        "artifact_sha256": artifacts,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs", type=Path, default=REPO / ".local" / "protocol-security")
    parser.add_argument("--report", type=Path, help="also refresh checked-in security evidence")
    parser.add_argument("--timeout", type=int, default=120, help="seconds per scenario; no proof-depth cap")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("Pinned security toolchain requires Linux x86-64")
    sources = {str(p.relative_to(REPO)) for p in ROOT.parent.rglob("*.spthy")}
    if sources != {c[1] for c in CHECKS}:
        raise RuntimeError("Symbolic model files and the check inventory differ")
    input_hashes = {source: digest(REPO / source) for source in sorted(sources)}
    checker_hash = digest(Path(__file__))
    tamarin, maude = toolchain("tamarin"), toolchain("maude")
    version = subprocess.run(
        [str(tamarin), f"--with-maude={maude}", "--version"],
        check=True, capture_output=True, text=True, timeout=30,
    ).stdout
    if f"tamarin-prover {TOOLS['tamarin']['version']}," not in version:
        raise RuntimeError("Unexpected Tamarin version")
    maude_version = subprocess.run(
        [str(maude), "--version"], check=True, capture_output=True, text=True, timeout=10,
    ).stdout.strip()
    if maude_version != TOOLS["maude"]["version"]:
        raise RuntimeError("Unexpected Maude version")
    logs = args.logs.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    checks = [run_check(c, tamarin, maude, logs, args.timeout) for c in CHECKS]
    inputs_unchanged = (all(digest(REPO / p) == h for p, h in input_hashes.items())
                        and digest(Path(__file__)) == checker_hash
                        and all(c["source_sha256"] == input_hashes[c["source"]] for c in checks))
    report = {
        "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "Unbounded symbolic safety under documented primitive, policy and channel assumptions",
        "passed": inputs_unchanged and all(c["expectation_met"] for c in checks),
        "inputs_unchanged": inputs_unchanged,
        "tools": TOOLS, "checker_sha256": checker_hash, "checks": checks,
    }
    serialized = json.dumps(report, indent=2) + "\n"
    (logs / "report.json").write_text(serialized)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(serialized)
    count = sum(len(c["results"]) for c in checks)
    if not inputs_unchanged:
        print("Inputs changed during verification; rerun against one source revision.", file=sys.stderr)
    print(f"{sum(c['expectation_met'] for c in checks)}/{len(checks)} scenarios match; "
          f"{count} selected properties, including attack controls; logs: {logs}")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"security check failed: {exc}", file=sys.stderr)
        sys.exit(1)
