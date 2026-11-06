#!/usr/bin/env python3
"""Build the Factorio mod zip: dist/<name>_<version>.zip

Factorio expects every file inside a top-level folder named <name>_<version>.
Development-only files (tests, tools, CI config) are left out.
"""
import json
import os
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INCLUDE = [
    "info.json", "changelog.txt", "control.lua", "data.lua", "settings.lua",
    "README.md", "API_REFERENCE.md", "EXAMPLES.md", "screenshot.png",
    "locale", "scripts", "examples",
]


def main():
    info = json.load(open(os.path.join(ROOT, "info.json"), encoding="utf-8"))
    folder = f"{info['name']}_{info['version']}"
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    out = os.path.join(ROOT, "dist", folder + ".zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for entry in INCLUDE:
            path = os.path.join(ROOT, entry)
            if os.path.isfile(path):
                z.write(path, f"{folder}/{entry}")
                continue
            for dirpath, _, files in sorted(os.walk(path)):
                for f in sorted(files):
                    full = os.path.join(dirpath, f)
                    z.write(full, f"{folder}/{os.path.relpath(full, ROOT)}")
    print(out)


if __name__ == "__main__":
    main()
