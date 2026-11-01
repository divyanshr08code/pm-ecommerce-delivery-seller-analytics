"""Check that numbers quoted in the docs appear in docs/RESULTS.md.

What it checks: percentages, decimals and integers above 31, outside code fences. Smaller integers
are mostly counts of things ("3 waves"), and they are too common to check this way.
What it skips: years and values in DEFINITIONAL (thresholds and design choices, not results), and
anything between <!-- audit:off --> and <!-- audit:on --> (hand worked examples and planning
assumptions, labelled as such in the text).
A failure stops the build, so a stale number cannot be published quietly.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ["README.md", "docs/METRICS.md",
        "docs/DATA_QUALITY.md", "dashboard/BUILD_GUIDE.md"]
# Other notes in docs/ are checked when present, except these, which do not quote results.
NOT_RESULTS = {"RESULTS.md", "DECISIONS.md", "SKILLS_CHECKLIST.md", "PLAN.md", "PROGRESS.md", "NEEDS_FROM_ME.md"}
# Thresholds, percentile names and design inputs that are chosen, not measured.
DEFINITIONAL = {"100", "500", "300", "50", "75", "90", "33%", "25%", "50%", "80%", "95%", "5%", "1.96", "0.84", "2.8",
                "7.84", "0.01", "0.3", "1.5", "0.12", "12%", "20%", "30%", "86400", "6371", "4.0", "0.5", "0.05", "99", "100%",
                "0%", "60", "2.0", "1.0", "0.9", "10%", "1200", "900"}
NUMBER = re.compile(r"(?<![\w.#/-])\d[\d,]*(?:\.\d+)?%?(?![\w/-])")


def known_values():
    results = json.loads((ROOT / "outputs" / "results.json").read_text(encoding="utf-8"))
    known = set()
    for item in results.values():
        shown = item["shown"].replace("R$ ", "")
        known.add(shown.replace(",", ""))
        known.add(shown.lstrip("-").replace(",", ""))
    return known


def is_checked(token):
    plain = token.rstrip("%")
    if token.endswith("%") or "." in plain:
        return True
    return int(plain) > 31


def audit(path, known):
    problems, checked = [], 0
    in_fence = off = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.startswith("```"):
            in_fence = not in_fence
            continue
        if "<!-- audit:off" in line:
            off = True
        if "<!-- audit:on" in line:
            off = False
            continue
        if in_fence or off or line.startswith("#"):
            continue
        # Dates, years, list numbering, table/file references and identifiers are not results.
        clean = re.sub(r"`[^`]*`|\]\([^)]*\)|\b(19|20)\d\d-\d\d(-\d\d)?\b|\b(19|20)\d\d\b|^\s*\d+\.\s", " ", line)
        for match in NUMBER.findall(clean):
            token = match.rstrip(",").replace(",", "")
            if not token or not is_checked(token) or token in DEFINITIONAL:
                continue
            checked += 1
            if token not in known:
                problems.append(f"{path.relative_to(ROOT)}:{number}: {match}  | {line.strip()[:90]}")
    return problems, checked


def main():
    known = known_values()
    problems, total = [], 0
    extra = [f"docs/{p.name}" for p in sorted((ROOT / "docs").glob("*.md"))
             if p.name not in NOT_RESULTS and f"docs/{p.name}" not in DOCS]
    for doc in DOCS + extra:
        path = ROOT / doc
        if not path.exists():
            problems.append(f"{doc}: file is missing")
            continue
        found, checked = audit(path, known)
        problems += found
        total += checked
        print(f"{doc}: {checked} numbers checked, {len(found)} not in RESULTS.md")
    for problem in problems:
        print("  " + problem)
    print(f"Audit: {total} numbers checked, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
