#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from argparse import ArgumentParser


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

    print(f"version={version or ''}")
    print(f"is_beta={str(is_beta).lower()}")
    print(f"Found version: {version} (beta: {is_beta})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
