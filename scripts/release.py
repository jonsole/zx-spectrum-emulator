#!/usr/bin/env python3
"""Cuts a release of the emulator and the VS Code extension -- up to the tag.

    python scripts/release.py 0.1.0 --rc 1   # a release candidate: v0.1.0-rc1
    python scripts/release.py 0.1.0          # the release: v0.1.0

Sets package.json's version (the one number for both: cpp-core/CMakeLists.txt
reads it too), and for a release moves CHANGELOG.md's "Unreleased" section
under a heading of its own. Commits those two files -- by name, since the
working tree often holds other work -- and tags the commit. Pushes nothing:

    git push origin master v0.1.0

is what starts .github/workflows/release.yml, which builds, tests, packages
and publishes. A candidate leaves the changelog alone -- its notes are the
Unreleased section as it stands -- and is published as a GitHub pre-release.

Two more, which the workflow runs:

    python scripts/release.py check v0.1.0-rc1   # the tag matches package.json?
    python scripts/release.py notes v0.1.0       # the release notes, on stdout
"""
import datetime
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(ROOT, "vscode-extension", "package.json")
CHANGELOG = os.path.join(ROOT, "CHANGELOG.md")
UNRELEASED = "## Unreleased"

VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
TAG = re.compile(r"^v(\d+\.\d+\.\d+)(?:-rc(\d+))?$")


def git(*args, check=True):
    return subprocess.run(["git", *args], cwd=ROOT, check=check, capture_output=True,
                          text=True).stdout.strip()


def read(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def package_version():
    return json.loads(read(PACKAGE))["version"]


def set_package_version(version):
    # A text edit rather than json.dump, so the file keeps its own layout and
    # the diff is the one line.
    text = read(PACKAGE)
    updated, count = re.subn(r'("version":\s*")[^"]*(")', r"\g<1>" + version + r"\g<2>", text, count=1)
    if count != 1:
        raise SystemExit("no version in package.json")
    write(PACKAGE, updated)


def sections(text):
    """CHANGELOG.md's "## " sections, as (heading, body) in order."""
    found = []
    for match in re.finditer(r"^## (.+?)\s*$", text, re.M):
        found.append((match.group(1), match.start(), match.end()))
    out = []
    for i, (heading, start, end) in enumerate(found):
        stop = found[i + 1][1] if i + 1 < len(found) else len(text)
        out.append((heading, text[end:stop].strip("\r\n")))
    return out


def notes_for(version, rc):
    """A release's notes: its own section, or for a candidate, Unreleased."""
    wanted = "Unreleased" if rc else version
    for heading, body in sections(read(CHANGELOG)):
        if heading == wanted or heading.startswith(wanted + " "):
            if rc:
                return f"Release candidate {rc} for {version}.\n\n{body}\n"
            return body + "\n"
    raise SystemExit(f"CHANGELOG.md has no section for {wanted}")


def parse_tag(tag):
    match = TAG.match(tag)
    if not match:
        raise SystemExit(f"{tag} is not a release tag (v1.2.3, or v1.2.3-rc1)")
    return match.group(1), match.group(2)


def command_check(tag):
    version, rc = parse_tag(tag)
    if version != package_version():
        raise SystemExit(f"{tag} is not package.json's version, {package_version()}")
    # For GitHub Actions' $GITHUB_OUTPUT: what the later steps need to know.
    print(f"version={version}")
    print(f"prerelease={'true' if rc else 'false'}")
    print(f"suffix={'rc' + rc if rc else ''}")
    return 0


def command_notes(tag):
    version, rc = parse_tag(tag)
    sys.stdout.write(notes_for(version, rc))
    return 0


def command_prepare(version, rc):
    if not VERSION.match(version):
        raise SystemExit(f"{version} is not a version (1.2.3)")
    tag = f"v{version}" + (f"-rc{rc}" if rc else "")
    if git("rev-parse", "--abbrev-ref", "HEAD") != "master":
        raise SystemExit("releases are cut from master")
    if git("tag", "--list", tag):
        raise SystemExit(f"{tag} already exists")
    # The two files this commits must hold nothing else: a half-finished edit
    # to either would go out with the release.
    for path in (PACKAGE, CHANGELOG):
        if git("status", "--porcelain", "--", path):
            raise SystemExit(f"{os.path.relpath(path, ROOT)} has uncommitted changes")

    changed = []
    if package_version() != version:
        set_package_version(version)
        changed.append(PACKAGE)
    if not rc:
        text = read(CHANGELOG)
        bodies = dict(sections(text))
        if not bodies.get("Unreleased", "").strip():
            raise SystemExit("CHANGELOG.md's Unreleased section is empty: say what is in the release")
        date = datetime.date.today().isoformat()
        text = text.replace(UNRELEASED, f"{UNRELEASED}\n\n## {version} ({date})", 1)
        write(CHANGELOG, text)
        changed.append(CHANGELOG)
    else:
        notes_for(version, rc)  # fails now, not in CI, if there is nothing to say

    if changed:
        paths = [os.path.relpath(p, ROOT) for p in changed]
        git("add", "--", *paths)
        # --only with the paths: whatever else is staged stays out of it.
        git("commit", "--only", "-m", f"Release {version}" + (f" candidate {rc}" if rc else ""),
            "--", *paths)
    git("tag", "-a", tag, "-m", f"zx-spectrum-emulator {tag[1:]}")
    print(f"Tagged {tag} at {git('rev-parse', '--short', 'HEAD')}"
          + (f" (committed {', '.join(os.path.basename(p) for p in changed)})" if changed else ""))
    print(f"Look it over, then publish it with:  git push origin master {tag}")
    return 0


def main(argv):
    if len(argv) == 2 and argv[0] == "check":
        return command_check(argv[1])
    if len(argv) == 2 and argv[0] == "notes":
        return command_notes(argv[1])
    if len(argv) == 1:
        return command_prepare(argv[0], None)
    if len(argv) == 3 and argv[1] == "--rc" and argv[2].isdigit() and int(argv[2]) > 0:
        return command_prepare(argv[0], argv[2])
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
