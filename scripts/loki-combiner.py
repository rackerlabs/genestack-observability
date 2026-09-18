#!/usr/bin/env python3

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


def sanitize_name(value: str, max_len: int = 253) -> str:
    """
    Convert a string into something safe for Kubernetes metadata.name.
    """
    value = value.lower()
    value = re.sub(r"[^a-z0-9.-]+", "-", value)
    value = re.sub(r"-{2,}", "-", value)
    value = value.strip("-.")
    if not value:
        value = "rule"
    return value[:max_len].strip("-.")


def sanitize_key(value: str) -> str:
    """
    Make a safe ConfigMap data key from a relative path.
    Keeps dots, dashes, underscores, and slashes out by flattening to dashes.
    """
    value = value.replace("\\", "/")
    value = value.strip("/")
    value = re.sub(r"[^A-Za-z0-9._-]+", "-", value.replace("/", "-"))
    value = re.sub(r"-{2,}", "-", value)
    value = value.strip("-")
    return value or "rule.yaml"


def indent_block(text: str, spaces: int = 4) -> str:
    prefix = " " * spaces
    lines = text.splitlines()
    if not lines:
        return prefix
    return "\n".join(prefix + line for line in lines)


def build_configmap(
    file_path: Path,
    root_dir: Path,
    namespace: str,
    label_key: str,
    label_value: str,
) -> str:
    rel_path = file_path.relative_to(root_dir)
    rel_no_suffix = rel_path.with_suffix("")
    name_part = sanitize_name(str(rel_no_suffix).replace("/", "-").replace("\\", "-"))
    configmap_name = sanitize_name(f"loki-rules-{name_part}")

    # Use relative path in the data key so files with the same basename do not collide.
    key_name = sanitize_key(str(rel_path))

    content = file_path.read_text(encoding="utf-8").rstrip("\n")

    doc = f"""apiVersion: v1
kind: ConfigMap
metadata:
  name: {configmap_name}
  namespace: {namespace}
  labels:
    {label_key}: "{label_value}"
data:
  {key_name}: |
{indent_block(content, 4)}
"""
    return doc


def find_rule_files(root_dir: Path, output_file: Path) -> list[Path]:
    files: list[Path] = []
    for path in sorted(root_dir.rglob("*")):
        if not path.is_file():
            continue
        if path.resolve() == output_file.resolve():
            continue
        if path.suffix.lower() not in {".yaml", ".yml"}:
            continue
        files.append(path)
    return files


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate a multi-document loki-rules.yaml from nested rule files."
    )
    parser.add_argument(
        "root_dir",
        help="Root directory to scan for rule YAML files.",
    )
    parser.add_argument(
        "-o",
        "--output",
        default="loki-rules.yaml",
        help="Output file path. Default: loki-rules.yaml",
    )
    parser.add_argument(
        "-n",
        "--namespace",
        default="monitoring",
        help="Namespace for generated ConfigMaps. Default: monitoring",
    )
    parser.add_argument(
        "--label-key",
        default="loki_rule",
        help='ConfigMap discovery label key. Default: "loki_rule"',
    )
    parser.add_argument(
        "--label-value",
        default="1",
        help='ConfigMap discovery label value. Default: "1"',
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    root_dir = Path(args.root_dir).expanduser().resolve()
    output_file = Path(args.output).expanduser().resolve()

    if not root_dir.exists():
        print(f"error: root directory does not exist: {root_dir}", file=sys.stderr)
        return 1
    if not root_dir.is_dir():
        print(f"error: root path is not a directory: {root_dir}", file=sys.stderr)
        return 1

    rule_files = find_rule_files(root_dir, output_file)
    if not rule_files:
        print(f"error: no .yaml or .yml files found under: {root_dir}", file=sys.stderr)
        return 1

    docs = [
        build_configmap(
            file_path=path,
            root_dir=root_dir,
            namespace=args.namespace,
            label_key=args.label_key,
            label_value=args.label_value,
        )
        for path in rule_files
    ]

    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text("---\n".join(docs), encoding="utf-8")

    print(f"wrote {len(rule_files)} ConfigMap(s) to {output_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
