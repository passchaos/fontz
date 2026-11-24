#!/usr/bin/env python3
"""Check the real Zig package export; optional gates run from exported files."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

FORBIDDEN = {".git", ".zig-cache", "zig-out", "zig-pkg", "__pycache__", ".DS_Store"}


def run(command, cwd):
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError("Command failed: " + " ".join(command) + "\n" + result.stdout + result.stderr)
    return result.stdout.strip()


def extract(archive, destination):
    with tarfile.open(archive) as source:
        for item in source.getmembers():
            relative = PurePosixPath(item.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError("Package path escapes export: " + item.name)
            target = destination.joinpath(*relative.parts)
            if item.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif item.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.extractfile(item) as data, target.open("wb") as output:
                    shutil.copyfileobj(data, output)
                target.chmod(item.mode)
            else:
                raise RuntimeError("Unexpected package member: " + item.name)


def verify(args):
    root = Path(args.repo).resolve()
    build = (root / "build.zig").read_text()
    required = set(re.findall(r'b\.path\("([^"\n]+)"\)', build))
    required.add("tests/coretext_matching_test.zig")
    with tempfile.TemporaryDirectory(prefix="fontz-package-export-") as temporary:
        work = Path(temporary)
        cache = work / "cache"
        # A minimal independent consumer also supports toolchains that resolve
        # package materialization through a current build workspace.
        run([args.zig, "init", "--minimal"], work)
        package_hash = run([args.zig, "fetch", "--global-cache-dir", str(cache), str(root)], work)
        if not re.fullmatch(r"fontz-[A-Za-z0-9._-]+", package_hash):
            raise RuntimeError("Unexpected package hash: " + package_hash)
        archive = cache / "p" / (package_hash + ".tar.gz")
        directory = cache / "p" / package_hash
        exported = work / "exported"
        exported.mkdir()
        if archive.is_file():
            extract(archive, exported)
            package = exported / package_hash
        elif directory.is_dir():
            package = exported / package_hash
            shutil.copytree(directory, package, symlinks=True)
        else:
            # Toolchains that materialize packages relative to cwd keep these
            # artifacts inside the temporary directory, never in the source repo.
            materialized = work / "zig-pkg" / package_hash
            if not materialized.is_dir():
                raise RuntimeError("Fetched package was not materialized")
            package = exported / package_hash
            shutil.copytree(materialized, package, symlinks=True)
        files = sorted(p for p in package.rglob("*") if p.is_file())
        for path in package.rglob("*"):
            relative = path.relative_to(package)
            if any(part in FORBIDDEN for part in relative.parts) or path.suffix == ".pyc" or path.is_symlink():
                raise RuntimeError("Generated or linked file in export: " + str(relative))
        missing = sorted(name for name in required if not (package / name).is_file())
        if missing:
            raise RuntimeError("Missing published build input: " + ", ".join(missing))
        gates = []
        base = [args.zig, "build", "--cache-dir", str(work / "build-cache"),
                "--global-cache-dir", str(work / "build-global-cache")]
        if args.configure:
            run(base + ["--help"], package)
            gates.append("build-graph")
        if args.metadata_tests:
            run([args.zig, "test", "src/metadata_index.zig", "--cache-dir", str(work / "test-cache"),
                 "--global-cache-dir", str(work / "test-global-cache"),
                 "--test-filter", "face location", "--test-filter", "PostScript lookup",
                 "--test-filter", "TT collection", "--test-filter", "metadata cache",
                 "--test-filter", "fvar"], package)
            gates.append("focused-metadata")
        if args.check:
            run(base + ["check", "-j1", "--summary", "all"], package)
            gates.append("platform-declarations")
        if args.macos_oracle:
            if sys.platform != "darwin":
                raise RuntimeError("CoreText oracle requires a macOS host")
            run(base + ["test-macos-coretext", "-j1", "--summary", "all"], package)
            gates.append("macos-coretext")
        return {"schema_version": 1, "package_hash": package_hash,
                "zig_version": run([args.zig, "version"], work),
                "source": str(root), "exported_file_count": len(files),
                "required_build_inputs": sorted(required), "gates": gates,
                "files": {str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files
                          if not any(part in FORBIDDEN for part in p.relative_to(package).parts)}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--report", required=True)
    parser.add_argument("--configure", action="store_true")
    parser.add_argument("--metadata-tests", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--macos-oracle", action="store_true")
    args = parser.parse_args()
    try:
        report = verify(args)
    except (OSError, RuntimeError, tarfile.TarError) as error:
        print(error, file=sys.stderr)
        return 1
    target = Path(args.report)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(report, indent=2) + "\n")
    print("package export verified:", report["package_hash"], "gates:", ", ".join(report["gates"]) or "metadata")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
