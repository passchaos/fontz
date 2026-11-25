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


def run(command, cwd, log=False):
    if log:
        print("run from exported package:", " ".join(command), "cwd:", cwd, flush=True)
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError("Command failed: " + " ".join(command) + "\n" + result.stdout + result.stderr)
    if log:
        print(result.stdout, end="", flush=True)
        print(result.stderr, end="", file=sys.stderr, flush=True)
        return (result.stdout + result.stderr).strip()
    return result.stdout.strip()


def named_tests(package, files, prefix):
    names = []
    for name in files:
        names.extend(re.findall(r'^test\s+"(' + re.escape(prefix) + r'[^"\n]*)"',
                                (package / name).read_text(), re.MULTILINE))
    if not names or len(names) != len(set(names)):
        raise RuntimeError("Missing or duplicate exported named tests for " + prefix)
    return names


def test_counts(package, output, build_step, files, prefix, unnamed):
    names = named_tests(package, files, prefix)
    expected = len(names) + unnamed
    summary = re.search(r"Build Summary:[^\n]*; (\d+)/(\d+) tests passed", output)
    if not summary or tuple(map(int, summary.groups())) != (expected, expected):
        raise RuntimeError("Exported " + build_step + " did not execute all " +
                           str(len(names)) + " named and " + str(unnamed) + " unnamed tests")
    return {"build_step": build_step, "named_test_count": len(names),
            "unnamed_test_count": unnamed, "passed": expected, "total": expected,
            "named_tests": names}


def matching_test_counts(package, output):
    # Explicit named counts catch a gate accidentally rooted at src/root.zig,
    # which can otherwise succeed after executing only declaration checks.
    return test_counts(package, output, "test-coverage-matching",
                       ["src/coverage_matching_tests.zig", "src/variation_matching_tests.zig"],
                       "coverage matching", 2)


def variation_test_counts(package, output):
    return test_counts(package, output, "test-variation-sequences",
                       ["src/root.zig", "src/metadata/variation_tests.zig",
                        "src/metadata/variation_cache_tests.zig", "src/variation_fallback_tests.zig",
                        "src/query_cache.zig"], "variation sequence", 3)


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
        gate_results = {}
        base = [args.zig, "build", "--cache-dir", str(work / "build-cache"),
                "--global-cache-dir", str(work / "build-global-cache")]
        if args.configure:
            run(base + ["--help", "-j1"], package, log=True)
            gates.append("build-graph")
        if args.metadata_tests:
            run([args.zig, "test", "src/metadata_index.zig", "--cache-dir", str(work / "test-cache"),
                 "--global-cache-dir", str(work / "test-global-cache"),
                 "--test-filter", "face location", "--test-filter", "PostScript lookup",
                 "--test-filter", "TT collection", "--test-filter", "metadata cache",
                 "--test-filter", "fvar", "-j1"], package, log=True)
            gates.append("focused-metadata")
        if args.check:
            run(base + ["check", "-j1", "--summary", "all"], package, log=True)
            gates.append("platform-declarations")
        if args.concurrency_tests:
            run(base + ["test-concurrency", "-j1", "--summary", "all"], package, log=True)
            gates.append("catalog-concurrency")
        if args.coverage_matching_tests:
            output = run(base + ["test-coverage-matching", "-j1", "--summary", "all"], package, log=True)
            gate_results["catalog-coverage-matching"] = matching_test_counts(package, output)
            gates.append("catalog-coverage-matching")
        if args.variation_sequence_tests:
            output = run(base + ["test-variation-sequences", "-j1", "--summary", "all"], package, log=True)
            gate_results["variation-sequences"] = variation_test_counts(package, output)
            gates.append("variation-sequences")
            output = run(base + ["test-variation-api", "-j1", "--summary", "all"], package, log=True)
            gate_results["variation-api"] = test_counts(package, output, "test-variation-api",
                ["tests/variation_api_test.zig"], "variation sequence published API", 0)
            gates.append("variation-api")
        if args.prepared_cmap_tests:
            output = run(base + ["test-prepared-cmap", "-j1", "--summary", "all"], package, log=True)
            gate_results["prepared-cmap"] = test_counts(package, output, "test-prepared-cmap",
                ["src/metadata/prepared_tests.zig"], "prepared cmap", 1)
            gates.append("prepared-cmap")
        if args.unicode_cmap_tests:
            output = run(base + ["test-unicode-cmap", "-j1", "--summary", "all"], package, log=True)
            gate_results["unicode-cmap"] = test_counts(package, output, "test-unicode-cmap",
                ["src/metadata/numeric_unit_tests.zig", "src/metadata/numeric_cache_tests.zig",
                 "src/metadata/numeric_discovery_tests.zig"], "unicode cmap", 2)
            gates.append("unicode-cmap")
        if args.macos_oracle:
            if sys.platform != "darwin":
                raise RuntimeError("CoreText oracle requires a macOS host")
            run(base + ["test-macos-coretext", "-j1", "--summary", "all"], package, log=True)
            gates.append("macos-coretext")
        return {"schema_version": 1, "package_hash": package_hash,
                "zig_version": run([args.zig, "version"], work),
                "source": str(root), "exported_file_count": len(files),
                "required_build_inputs": sorted(required), "gates": gates, "gate_results": gate_results,
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
    parser.add_argument("--concurrency-tests", action="store_true")
    parser.add_argument("--coverage-matching-tests", action="store_true")
    parser.add_argument("--variation-sequence-tests", action="store_true")
    parser.add_argument("--prepared-cmap-tests", action="store_true")
    parser.add_argument("--unicode-cmap-tests", action="store_true")
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
