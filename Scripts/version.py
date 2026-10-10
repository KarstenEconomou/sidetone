#!/usr/bin/env python3
import argparse
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
COMMIT_TITLE = re.compile(
    r"(feat|fix|perf|refactor|test|build|ci|chore|docs|style|revert)"
    r"\([a-z0-9][a-z0-9._/-]*\)!?: .+"
)


def parse_version(value):
    if not SEMVER.fullmatch(value):
        raise ValueError(f"Use a stable semantic version, such as 1.0.0: {value}")
    return tuple(int(part) for part in value.split("."))


def git(*arguments):
    return subprocess.check_output(["git", *arguments], cwd=ROOT, text=True).strip()


def current_version():
    value = (ROOT / "VERSION").read_text().strip()
    parse_version(value)
    return value


def latest_release(exclude=None):
    releases = []
    for tag in git("tag", "--list", "v*").splitlines():
        if tag != exclude and SEMVER.fullmatch(tag[1:]):
            releases.append((parse_version(tag[1:]), tag))
    if not releases:
        return None
    version, tag = max(releases)
    if subprocess.run(
        ["git", "merge-base", "--is-ancestor", tag, "HEAD"], cwd=ROOT
    ).returncode:
        raise ValueError(f"The branch must include the latest release: {tag}")
    return version, tag


def next_version(exclude=None):
    release = latest_release(exclude)
    if release is None:
        return "1.0.0"
    (major, minor, patch), tag = release
    messages = git("log", "--format=%B", "-z", f"{tag}..HEAD").split("\0")
    messages = [message.strip() for message in messages if message.strip()]
    if not messages:
        raise ValueError(f"There are no changes after {tag}.")
    if any(
        re.search(r"^[a-z]+(?:\([^)]+\))?!:|^BREAKING(?: CHANGE|-CHANGE):", message, re.M)
        for message in messages
    ):
        return f"{major + 1}.0.0"
    if any(re.match(r"feat(?:\([^)]+\))?:", message) for message in messages):
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def check_version():
    current = current_version()
    release = latest_release()
    if release is not None and parse_version(current) == release[0]:
        return current
    expected = next_version()
    if current != expected:
        raise ValueError(f"VERSION must be {expected}; found {current}.")
    return current


def check_release(expected):
    parse_version(expected)
    if current_version() != expected:
        raise ValueError(f"The release version must match VERSION: {current_version()}")
    tag = f"v{expected}"
    if tag in git("tag", "--list", tag).splitlines():
        if git("rev-parse", f"{tag}^{{commit}}") != git("rev-parse", "HEAD"):
            raise ValueError(f"The release tag points to another commit: {tag}")
    required = next_version(exclude=tag)
    if expected != required:
        raise ValueError(f"The changes require version {required}; found {expected}.")
    return expected


def check_title(title):
    if not COMMIT_TITLE.fullmatch(title):
        raise ValueError("Use a Conventional Commit title: type(scope): description")


def main():
    parser = argparse.ArgumentParser(description="Check and select release versions.")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ["current", "next", "check"]:
        commands.add_parser(name)
    commands.add_parser("release").add_argument("version")
    commands.add_parser("title").add_argument("title")
    args = parser.parse_args()
    try:
        if args.command == "current":
            print(current_version())
        elif args.command == "next":
            print(next_version())
        elif args.command == "check":
            print(check_version())
        elif args.command == "release":
            print(check_release(args.version))
        else:
            check_title(args.title)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
