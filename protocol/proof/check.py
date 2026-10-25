#!/usr/bin/env python3
"""Kernel-check unbounded signaling theorems and audit every declaration's axioms."""

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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--logs", type=Path, default=REPO / ".local" / "protocol-proof")
    parser.add_argument("--report", type=Path, help="also refresh the checked-in proof evidence")
    args = parser.parse_args()
    source = ROOT / "Signaling.lean"
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
    if "signaling_and_candidates_converge" not in declarations:
        raise RuntimeError("The composed convergence theorem is missing")
    lean, version = lean_toolchain()
    logs = args.logs.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    # A fresh direct source compilation prevents a stale local .olean from
    # substituting for the actual checked-in proof. No Lake or external library.
    audit = content + "\n" + "\n".join(f"#print axioms Signaling.{name}" for name in declarations) + "\n"
    with tempfile.TemporaryDirectory(prefix="mesh-lean-") as temporary:
        proof = Path(temporary) / "Signaling.lean"
        proof.write_text(audit)
        proc = subprocess.run([str(lean), "-DwarningAsError=true", str(proof)],
                              capture_output=True, text=True, timeout=180, check=False)
    output = proc.stdout + proc.stderr
    (logs / "kernel-and-axioms.log").write_text(output)
    dependencies = {}
    pattern = r"'Signaling\.(\w+)' (?:depends on axioms: \[([^\]]*)\]|does not depend on any axioms)"
    for match in re.finditer(pattern, output):
        dependencies[match[1]] = sorted(filter(None, (s.strip() for s in (match[2] or "").split(","))))
    unexpected = {name: sorted(set(axioms) - ALLOWED_AXIOMS) for name, axioms in dependencies.items()
                  if set(axioms) - ALLOWED_AXIOMS}
    passed = proc.returncode == 0 and set(dependencies) == set(declarations) and not unexpected
    report = {
        "checked_at_utc": datetime.now(timezone.utc).isoformat(),
        "scope": "Conditional unbounded signaling protocol proofs; no implementation, ICE, or attestation claim",
        "passed": passed,
        "tool": {"version": version, "archive_sha256": SHA256},
        "source": "proof/Signaling.lean", "source_sha256": digest(source),
        "checker_sha256": digest(Path(__file__)),
        "declaration_count": len(declarations),
        "allowed_logical_axioms": sorted(ALLOWED_AXIOMS),
        "axiom_dependencies": dependencies,
        "unexpected_axioms": unexpected,
    }
    serialized = json.dumps(report, indent=2) + "\n"
    (logs / "report.json").write_text(serialized)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(serialized)
    if not passed:
        print(output)
        raise RuntimeError(f"Lean verification/audit failed; logs: {logs}")
    print(f"PASS: {len(declarations)} declarations kernel-checked; composed signaling/candidate convergence; "
          f"no custom axioms or placeholders; logs: {logs}")


if __name__ == "__main__":
    main()
