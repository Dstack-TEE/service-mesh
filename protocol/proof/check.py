#!/usr/bin/env python3
"""Kernel-check protocol theorems and audit every authored declaration's axioms."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent.parent
VERSION = "4.35.0"
SHA256 = "7289597a44543246c9227b8cae501767e095ce17f6d448b95fc4a8dc97268f6d"
URL = f"https://github.com/leanprover/lean4/releases/download/v{VERSION}/lean-{VERSION}-linux.tar.zst"
ALLOWED_AXIOMS = {"propext", "Classical.choice", "Quot.sound"}
PROOFS = {
    "Signaling": {"signaling_and_candidates_converge", "finite_mesh_converges"},
    "AdmissionPolicy": {"authorization_sound", "selection_is_first_match",
                        "identity_index_preserves_selection",
                        "wildcard_shadowing_changes_grant",
                        "cross_row_evidence_mixing_is_rejected"},
    "SlotAllocation": {"corrected_allocation_never_duplicates", "step_preserves",
                       "old_request_can_commit_after_reset"},
}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def lean_toolchain():
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    cache = cache / "dstack-service-mesh" / "lean4" / VERSION
    cache.mkdir(parents=True, exist_ok=True)
    archive = Path(os.environ.get("LEAN4_ARCHIVE", cache / "lean-linux.tar.zst")).expanduser().resolve()
    if not archive.exists():
        if "LEAN4_ARCHIVE" in os.environ:
            raise RuntimeError(f"LEAN4_ARCHIVE does not exist: {archive}")
        with tempfile.TemporaryDirectory(dir=cache) as staging:
            download = Path(staging) / "download.tar.zst"
            print(f"Downloading pinned Lean {VERSION} (567 MiB)", flush=True)
            subprocess.run([
                "curl", "--fail", "--location", "--silent", "--show-error", "--max-time", "300",
                "--output", str(download), URL,
            ], check=True, timeout=310)
            if digest(download) != SHA256:
                raise RuntimeError("Lean archive checksum does not match the pin")
            download.replace(archive)
    if digest(archive) != SHA256:
        raise RuntimeError(f"Lean archive checksum does not match the pin: {archive}")
    toolchain = cache / f"lean-{VERSION}-linux"
    marker = toolchain / ".verified-archive-sha256"
    if not marker.exists() or marker.read_text().strip() != SHA256:
        print("Extracting verified Lean toolchain (3 GiB)", flush=True)
        subprocess.run(["tar", "--zstd", "-xf", str(archive), "-C", str(cache)], check=True, timeout=180)
        marker.write_text(SHA256 + "\n")
    lean = toolchain / "bin" / "lean"
    version = subprocess.run([str(lean), "--version"], check=True, capture_output=True, text=True).stdout.strip()
    if not version.startswith(f"Lean (version {VERSION},"):
        raise RuntimeError(f"Unexpected Lean version: {version}")
    return lean, version


def check_proof(namespace, lean, logs):
    source = ROOT / f"{namespace}.lean"
    content = source.read_text()
    # The dependency audit is authoritative; these checks also catch easy
    # accidental omissions, unchecked commands and unreviewed import changes.
    if re.findall(r"^import (.+)$", content, re.M) != ["Std"]:
        raise RuntimeError("Proof imports must be exactly the pinned Lean standard library")
    if re.search(r"\b(sorry|admit|native_decide|sorryAx)\b", content):
        raise RuntimeError("Proof contains an unchecked placeholder or native decision procedure")
    if re.search(r"^\s*(axiom|opaque|unsafe|partial)\b|^\s*set_option\s+(debug|compiler)", content, re.M):
        raise RuntimeError("Proof contains an unsupported trusted declaration/option")
    declarations = re.findall(r"^(?:theorem|def)\s+(\w+)\b", content, re.M)
    if len(declarations) != len(set(declarations)):
        raise RuntimeError("Duplicate declaration names")
    if not PROOFS[namespace].issubset(declarations):
        raise RuntimeError(f"Required {namespace} theorems are missing")
    # A fresh direct source compilation prevents a stale local .olean from
    # substituting for the actual checked-in proof. No Lake or external library.
    audit = content + "\n" + "\n".join(f"#print axioms {namespace}.{name}" for name in declarations) + "\n"
    with tempfile.TemporaryDirectory(prefix="mesh-lean-") as temporary:
        proof = Path(temporary) / source.name
        proof.write_text(audit)
        proc = subprocess.run([str(lean), "-DwarningAsError=true", str(proof)],
                              capture_output=True, text=True, timeout=180, check=False)
    output = proc.stdout + proc.stderr
    (logs / f"{namespace}-kernel-and-axioms.log").write_text(output)
    dependencies = {}
    pattern = rf"'{namespace}\.(\w+)' (?:depends on axioms: \[([^\]]*)\]|does not depend on any axioms)"
    for match in re.finditer(pattern, output):
        dependencies[match[1]] = sorted(filter(None, (s.strip() for s in (match[2] or "").split(","))))
    unexpected = {name: sorted(set(axioms) - ALLOWED_AXIOMS) for name, axioms in dependencies.items()
                  if set(axioms) - ALLOWED_AXIOMS}
    passed = proc.returncode == 0 and set(dependencies) == set(declarations) and not unexpected
    result = {
        "namespace": namespace, "passed": passed,
        "source": f"proof/{source.name}",
        "source_sha256": hashlib.sha256(content.encode()).hexdigest(),
        "declaration_count": len(declarations),
        "axiom_dependencies": dependencies,
        "unexpected_axioms": unexpected,
        "log": f"{namespace}-kernel-and-axioms.log",
    }
    print(f"{'PASS' if passed else 'FAIL'} {namespace}: {len(declarations)} declarations", flush=True)
    if not passed:
        print(output)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs", type=Path, default=REPO / ".local" / "protocol-proof")
    parser.add_argument("--report", type=Path, help="also refresh the checked-in proof evidence")
    args = parser.parse_args()
    actual = {p.stem for p in ROOT.glob("*.lean")}
    if actual != set(PROOFS):
        raise RuntimeError("Lean sources and proof inventory differ")
    checker_hash = digest(Path(__file__))
    lean, version = lean_toolchain()
    logs = args.logs.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    proofs = [check_proof(namespace, lean, logs) for namespace in PROOFS]
    inputs_unchanged = (checker_hash == digest(Path(__file__)) and
        all(p["source_sha256"] == digest(ROOT.parent / p["source"]) for p in proofs))
    report = {
        "schema_version": 2,
        "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "Unbounded signaling, policy authorization, and corrected no-cleanup slot ownership; separate specifications",
        "passed": inputs_unchanged and all(p["passed"] for p in proofs),
        "inputs_unchanged": inputs_unchanged,
        "tool": {"version": version, "archive_sha256": SHA256},
        "checker_sha256": checker_hash,
        "declaration_count": sum(p["declaration_count"] for p in proofs),
        "allowed_logical_axioms": sorted(ALLOWED_AXIOMS),
        "proofs": proofs,
    }
    serialized = json.dumps(report, indent=2) + "\n"
    (logs / "report.json").write_text(serialized)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(serialized)
    if not report["passed"]:
        raise RuntimeError(f"Lean verification/audit failed or inputs changed; logs: {logs}")
    print(f"PASS: {report['declaration_count']} declarations kernel-checked; "
          f"no custom axioms or placeholders; logs: {logs}")


if __name__ == "__main__":
    main()
