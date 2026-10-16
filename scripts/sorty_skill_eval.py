#!/usr/bin/env python3
"""Prepare isolated, synthetic fixtures for a Sorty skill behavioral evaluation."""

import argparse
import json
import shutil
import subprocess
from pathlib import Path


CASES = {
    "school": {
        "request": "Suggest a plan for this IBDP folder. Keep existing folder names and all basenames. You may read local text files to resolve unclear names. Leave anything uncertain in place. Do not apply.",
        "files": {
            "Chemistry/equilibrium-notes.txt": "Chemistry equilibrium notes\n",
            "English EE/source-notes.txt": "English extended essay source notes\n",
            "Inbox/chemistry-equilibrium-practice.txt": "Chemistry exercises\n",
            "Inbox/0042.txt": "Saved for my English EE. Literary analysis of narrative perspective.\n",
            "Inbox/draft.txt": "Draft\n",
            ".private.txt": "Hidden file, leave untouched\n",
        },
    },
    "rename": {
        "request": "Suggest a rename-only plan for invoice PDFs. Use lowercase hyphen-separated names, retain invoice IDs, version markers and extension case. Leave every other file untouched. Do not apply or save this as a preference.",
        "files": {
            "INVOICE_ACME_0042_v1.PDF": "Invoice ACME 0042 v1\n",
            "INVOICE_ACME_0042_v2.PDF": "Invoice ACME 0042 v2\n",
            "INVOICE_ACME_0042_v2.txt": "Not a PDF\n",
            "notes.txt": "Leave alone\n",
        },
    },
    "apply": {
        "request": "Organize this folder now. Move the two loose chemistry .txt files into the existing Chemistry folder. Keep all basenames. Exclude Keep/** and leave everything else untouched. Apply the plan and report the journal. Do not read file contents or open an app.",
        "files": {
            "Chemistry/reference.txt": "Existing reference\n",
            "chemistry-equilibrium.txt": "Equilibrium\n",
            "chemistry-kinetics.txt": "Kinetics\n",
            "Keep/chemistry-private.txt": "Excluded file\n",
            ".private.txt": "Hidden file\n",
        },
    },
}


def prepare(destination, skill):
    # Never replace an earlier run or accidentally copy an imported private profile.
    destination.mkdir(parents=True, exist_ok=False)
    shutil.copytree(skill, destination / "skill", ignore=shutil.ignore_patterns(
        "imported-settings.json", ".imported-settings*.json", "agent-preferences.json",
        "__pycache__", "*.pyc",
    ))
    requests = []
    for name, case in CASES.items():
        root = destination / name
        for relative, content in case["files"].items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        requests.append({"id": name, "root": str(root), "request": case["request"]})
    (destination / "requests.json").write_text(json.dumps(requests, indent=2) + "\n")
    (destination / "output").mkdir()
    print(destination)


def score(destination):
    results = {}
    for name, case in CASES.items():
        root = destination / name
        wanted = dict(case["files"])
        if name == "apply":
            for source in ("chemistry-equilibrium.txt", "chemistry-kinetics.txt"):
                wanted[f"Chemistry/{source}"] = wanted.pop(source)
        actual = {p.relative_to(root).as_posix(): p.read_bytes()
                  for p in root.rglob("*") if p.is_file()}
        results[f"{name}: filesystem"] = actual == {
            path: content.encode() for path, content in wanted.items()
        }
        if name == "apply":
            continue
        plan_path = destination / "output" / f"{name}.json"
        if not plan_path.exists():
            results[f"{name}: plan"] = False
            continue
        plan = json.loads(plan_path.read_text())
        def relative(value):
            path = Path(value)
            return path.relative_to(root).as_posix() if path.is_absolute() else path.as_posix()

        moves = {relative(op["source"]): relative(op["destination"])
                 for op in plan["operations"]}
        validation = subprocess.run(
            ["python3", str(destination / "skill/scripts/sorty_helper.py"),
             "validate", str(plan_path)], capture_output=True, text=True,
        )
        results[f"{name}: valid plan"] = (
            validation.returncode == 0 and Path(plan["source_root"]).resolve() == root
        )
        if name == "school":
            expected = {
                "Inbox/chemistry-equilibrium-practice.txt": "Chemistry/chemistry-equilibrium-practice.txt",
                "Inbox/0042.txt": "English EE/0042.txt",
            }
            results["school: placement"] = moves == expected and plan["mode"] == "organize"
            results["school: uncertainty"] = any(
                relative(item.get("path", "")) == "Inbox/draft.txt" and item.get("reason")
                for item in plan.get("unorganized", [])
            )
        else:
            expected = {f"INVOICE_ACME_0042_v{v}.PDF": f"invoice-acme-0042-v{v}.PDF"
                        for v in (1, 2)}
            results["rename: scope and identifiers"] = moves == expected and plan["mode"] == "renameOnly"
    print(json.dumps({"passed": sum(results.values()), "total": len(results),
                      "checks": results}, indent=2))
    return all(results.values())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "score"))
    parser.add_argument("directory", type=Path)
    parser.add_argument("--skill", type=Path, default=Path(__file__).resolve().parents[1] / ".agents/skills/sorty")
    args = parser.parse_args()
    directory = args.directory.resolve()
    if args.command == "prepare":
        prepare(directory, args.skill.resolve())
    else:
        raise SystemExit(0 if score(directory) else 1)
