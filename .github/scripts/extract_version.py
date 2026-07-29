#!/usr/bin/env python3

from __future__ import annotations

import os
import re
import stat
import sys
from argparse import ArgumentParser
from pathlib import Path


MAX_COMMENT_LENGTH = 100_000
MAX_VERSION_LENGTH = 255
MAX_NUMERIC_IDENTIFIER_LENGTH = 10
MAX_IDENTIFIER_LENGTH = 64
VERSION_CANDIDATE_RE = re.compile(
    rf"(?<![0-9A-Za-z.+-])v?[0-9][0-9A-Za-z.+-]{{2,{MAX_VERSION_LENGTH - 1}}}"
    rf"(?![0-9A-Za-z+-])"
)
IDENTIFIER_RE = re.compile(rf"^[0-9A-Za-z-]{{1,{MAX_IDENTIFIER_LENGTH}}}$")


def _valid_identifier_list(value: str, *, numeric_leading_zero_forbidden: bool) -> bool:
    identifiers = value.split(".")
    if not identifiers or len(identifiers) > 16:
        return False
    for identifier in identifiers:
        if not IDENTIFIER_RE.fullmatch(identifier):
            return False
        if (
            numeric_leading_zero_forbidden
            and identifier.isdigit()
            and len(identifier) > 1
            and identifier.startswith("0")
        ):
            return False
    return True


def parse_semver(candidate: str) -> tuple[str, bool] | None:
    value = candidate[1:] if candidate.startswith("v") else candidate
    if not value or len(value) > MAX_VERSION_LENGTH or value.count("+") > 1:
        return None

    version_and_prerelease, plus, build = value.partition("+")
    if plus and not _valid_identifier_list(
        build,
        numeric_leading_zero_forbidden=False,
    ):
        return None

    core, dash, prerelease = version_and_prerelease.partition("-")
    if dash and not _valid_identifier_list(
        prerelease,
        numeric_leading_zero_forbidden=True,
    ):
        return None

    core_parts = core.split(".")
    if len(core_parts) not in (2, 3):
        return None
    for part in core_parts:
        if (
            not part.isdigit()
            or len(part) > MAX_NUMERIC_IDENTIFIER_LENGTH
            or (len(part) > 1 and part.startswith("0"))
        ):
            return None

    return value, bool(dash)


def find_first_valid(text: str) -> tuple[str | None, bool]:
    bounded_text = (text or "")[:MAX_COMMENT_LENGTH]
    for match in VERSION_CANDIDATE_RE.finditer(bounded_text):
        candidate = match.group(0).rstrip(".,;:!?)]}")
        parsed = parse_semver(candidate)
        if parsed:
            return parsed
    return None, False


def _is_within(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def write_github_output(version: str | None, is_beta_flag: bool) -> None:
    raw_output_path = os.environ.get("GITHUB_OUTPUT")
    if not raw_output_path:
        return

    runner_temp = os.environ.get("RUNNER_TEMP")
    if not runner_temp:
        raise RuntimeError("RUNNER_TEMP is required when GITHUB_OUTPUT is set")

    output_path = Path(raw_output_path)
    if not output_path.is_absolute():
        raise RuntimeError("GITHUB_OUTPUT must be an absolute runner-managed path")

    trusted_root = Path(runner_temp).resolve(strict=True)
    resolved_output = output_path.resolve(strict=True)
    if not _is_within(resolved_output, trusted_root):
        raise RuntimeError("GITHUB_OUTPUT is outside RUNNER_TEMP")

    flags = os.O_WRONLY | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(output_path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise RuntimeError("GITHUB_OUTPUT is not a regular file")
        with os.fdopen(descriptor, "a", encoding="utf-8", closefd=False) as output:
            output.write(f"version={version or ''}\n")
            output.write(f"is_beta={str(is_beta_flag).lower()}\n")
            output.flush()
    finally:
        os.close(descriptor)


def main(argv=None) -> int:
    parser = ArgumentParser()
    parser.add_argument(
        "-c",
        "--comment",
        help="Comment body to scan (defaults: $COMMENT or stdin)",
    )
    args = parser.parse_args(argv)

    comment = args.comment or os.environ.get("COMMENT")
    if not comment:
        comment = sys.stdin.read(MAX_COMMENT_LENGTH + 1) or ""

    version, is_beta = find_first_valid(comment)
    write_github_output(version, is_beta)

    print(f"version={version or ''}")
    print(f"is_beta={str(is_beta).lower()}")
    print(f"Found version: {version} (beta: {is_beta})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
