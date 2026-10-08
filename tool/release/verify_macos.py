#!/usr/bin/env python3
"""Check actual Mach-O deployment targets, architectures, links and signatures."""
import argparse
import pathlib
import plistlib
import re
import subprocess


def output(*args):
    return subprocess.check_output(args, text=True)


def deployment_versions(loads):
    # Read only minimum OS load commands, never linker/source version fields.
    matches = re.findall(
        r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos ([0-9.]+)"
        r"|cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([0-9.]+)",
        loads,
    )
    return [modern or legacy for modern, legacy in matches]


def check_binary(path, *, archive=False, system_only=False):
    archs = output("lipo", "-archs", str(path)).strip().split()
    if archs != ["arm64"]:
        raise RuntimeError(f"{path}: expected arm64 only, got {archs}")
    loads = output("otool", "-l", str(path))
    # otool prints every archive member, so this verifies compiled objects too.
    versions = deployment_versions(loads)
    if not versions:
        raise RuntimeError(f"{path}: no deployment target load commands")
    for version in versions:
        parts = tuple(map(int, version.split(".")))
        if (parts + (0,) * (3 - len(parts))) > (12, 0, 0):
            raise RuntimeError(f"{path}: deployment target {version} exceeds macOS 12.0")
    if archive:
        # Every member must carry a target. Avoid validating just the archive header.
        members = re.findall(r"^.*\([^\n]+\):\s*$", loads, re.M)
        if not members or len(versions) != len(members):
            raise RuntimeError(f"{path}: could not verify every archive object's target")
    else:
        for line in output("otool", "-L", str(path)).splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            # A dylib's first entry may be its own install name.
            if dependency.startswith("@"):
                if system_only and pathlib.PurePosixPath(dependency).name != path.name:
                    raise RuntimeError(f"{path}: non-system dependency {dependency}")
            elif not dependency.startswith(("/usr/lib/", "/System/Library/")):
                raise RuntimeError(f"{path}: external dependency {dependency}")
    print(f"Verified {path}: arm64, macOS <=12.0 ({len(versions)} objects/slices)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--openssl", type=pathlib.Path)
    group.add_argument("--app", type=pathlib.Path)
    args = parser.parse_args()
    if args.openssl:
        for name in ("libssl.a", "libcrypto.a"):
            check_binary(args.openssl / "lib" / name, archive=True)
        return
    with (args.app / "Contents" / "Info.plist").open("rb") as stream:
        minimum = plistlib.load(stream).get("LSMinimumSystemVersion")
    if minimum is None or tuple(map(int, minimum.split(".")))[:2] > (12, 0):
        raise RuntimeError(f"App declares incompatible minimum macOS version: {minimum}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", str(args.app)], check=True)
    magic = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf"}
    binaries = []
    engines = []
    for path in args.app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as stream:
            if stream.read(4) not in magic:
                continue
        binaries.append(path)
        is_engine = "torrent_engine" in path.name
        if is_engine:
            engines.append(path)
        check_binary(path, system_only=is_engine)
    if not binaries or not engines:
        raise RuntimeError("App must contain its executable and the bundled torrent engine")


if __name__ == "__main__":
    main()
