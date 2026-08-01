#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="ios/FaceSwapLiveAppV17/Services/StyleSheetProvider.swift")
    parser.add_argument("--output", default="build/generated-js")
    args = parser.parse_args()

    source = Path(args.source)
    output = Path(args.output)
    text = source.read_text(encoding="utf-8")
    pattern = re.compile(
        r"static\s+(?:let|var)\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*:\s*String\s*(?:=\s*)?\{?\s*(?:return\s*)?\"\"\"\n(?P<body>[\s\S]*?)\n\s*\"\"\"",
        re.MULTILINE,
    )

    output.mkdir(parents=True, exist_ok=True)
    for existing in output.glob("*.js"):
        existing.unlink()

    manifest: list[dict[str, object]] = []
    for match in pattern.finditer(text):
        name = match.group("name")
        body = match.group("body") + "\n"
        destination = output / f"{name}.js"
        destination.write_text(body, encoding="utf-8")
        manifest.append({
            "name": name,
            "path": str(destination),
            "bytes": len(body.encode("utf-8")),
        })

    required = {"patchScript", "nativeWebRTCClientScript"}
    extracted = {entry["name"] for entry in manifest}
    missing = sorted(required - extracted)
    if missing:
        raise SystemExit(f"Missing required embedded scripts: {', '.join(missing)}")

    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"count": len(manifest), "required": sorted(required), "manifest": str(manifest_path)}))


if __name__ == "__main__":
    main()
