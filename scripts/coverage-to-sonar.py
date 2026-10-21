#!/usr/bin/env python3
"""Writes an Xcode result bundle's app coverage as SonarQube generic coverage.

    scripts/coverage-to-sonar.py build/TestResults.xcresult build/coverage.xml

Only the app and Top Shelf sources are kept. Sonar ignores coverage for test
files, and the engine package lives in its own repository.
"""
import json
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import quoteattr

SOURCE_ROOTS = ("Lagoon", "LagoonTopShelf")


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: coverage-to-sonar.py <result bundle> <output xml>")
    result, output = sys.argv[1:]
    root = Path(__file__).resolve().parent.parent
    archive = json.loads(subprocess.run(
        ["xcrun", "xccov", "view", "--archive", "--json", result],
        check=True, capture_output=True, text=True,
    ).stdout)

    lines = ['<coverage version="1">']
    files = 0
    for path in sorted(archive):
        try:
            relative = Path(path).resolve().relative_to(root)
        except ValueError:
            continue
        if relative.parts[0] not in SOURCE_ROOTS:
            continue
        executable = [line for line in archive[path] if line.get("isExecutable")]
        if not executable:
            continue
        files += 1
        lines.append(f"  <file path={quoteattr(relative.as_posix())}>")
        for line in executable:
            covered = "true" if line.get("executionCount", 0) > 0 else "false"
            lines.append(f'    <lineToCover lineNumber="{line["line"]}" covered="{covered}"/>')
        lines.append("  </file>")
    lines.append("</coverage>")

    if files == 0:
        sys.exit(f"error: {result} has no coverage for {', '.join(SOURCE_ROOTS)}")
    Path(output).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {output} ({files} files)")


if __name__ == "__main__":
    main()
