#!/usr/bin/env python3

import argparse
import copy
import hashlib
import re
import sys
from pathlib import Path

try:
    from ruamel.yaml import YAML
    from ruamel.yaml.scalarstring import DoubleQuotedScalarString
except ImportError:
    print("Missing dependency: ruamel.yaml", file=sys.stderr)
    print("Install it with: pip install ruamel.yaml", file=sys.stderr)
    sys.exit(1)


yaml = YAML()
yaml.preserve_quotes = False
yaml.default_flow_style = False
yaml.sort_base_mapping_type_on_output = False
yaml.width = 4096
yaml.indent(mapping=2, sequence=4, offset=2)

TOP_LEVEL_KEY_MAX_LEN = 30
HASH_LEN = 10


def load_yaml_file(file_path: Path):
    try:
        with file_path.open("r", encoding="utf-8") as f:
            data = yaml.load(f)
            return data if data is not None else {}
    except Exception as e:
        print(f"ERROR: Failed to read {file_path}: {e}", file=sys.stderr)
        return None


def find_yaml_files(root_dirs):
    yaml_files = []
    for root in root_dirs:
        root_path = Path(root)
        if not root_path.exists():
            print(f"WARNING: Root directory does not exist: {root}", file=sys.stderr)
            continue
        if not root_path.is_dir():
            print(f"WARNING: Not a directory: {root}", file=sys.stderr)
            continue

        yaml_files.extend(root_path.rglob("*.yaml"))
        yaml_files.extend(root_path.rglob("*.yml"))

    return sorted(set(yaml_files))


def normalize_multiline_to_escaped_string(value):
    if not isinstance(value, str):
        return value
    if "\n" in value:
        return DoubleQuotedScalarString(value)
    return value


def clean_expr(expr):
    """
    Flatten expr safely:
    - preserve all operators and punctuation
    - replace newlines/tabs with spaces
    - collapse repeated whitespace
    """
    if not isinstance(expr, str):
        return expr

    result = expr.replace("\r", " ").replace("\n", " ").replace("\t", " ")
    result = re.sub(r"\s+", " ", result).strip()

    if len(result) >= 2 and result[0] == '"' and result[-1] == '"':
        result = result[1:-1].strip()

    return result


def normalize_name(value: str) -> str:
    value = value.lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = re.sub(r"-+", "-", value).strip("-")
    return value


def split_timing_suffix(value: str):
    suffix_pattern = re.compile(
        r"^(.*?)(avg-over-time\d+[smhdwy]"
        r"|min-over-time\d+[smhdwy]"
        r"|max-over-time\d+[smhdwy]"
        r"|sum-over-time\d+[smhdwy]"
        r"|count-over-time\d+[smhdwy]"
        r"|quantile-over-time\d+[smhdwy]"
        r"|stddev-over-time\d+[smhdwy]"
        r"|stdvar-over-time\d+[smhdwy]"
        r"|last-over-time\d+[smhdwy]"
        r"|present-over-time\d+[smhdwy]"
        r"|irate\d+[smhdwy]"
        r"|rate\d+[smhdwy]"
        r"|increase\d+[smhdwy]"
        r"|idelta\d+[smhdwy]"
        r"|delta\d+[smhdwy]"
        r"|changes\d+[smhdwy]"
        r"|resets\d+[smhdwy])$"
    )

    match = suffix_pattern.fullmatch(value)
    if match:
        prefix, suffix = match.groups()
        return prefix.strip("-"), suffix
    return value, None


def shorten_with_hash(value: str, max_len: int = TOP_LEVEL_KEY_MAX_LEN) -> str:
    value = value.strip("-")
    if len(value) <= max_len:
        return value

    digest = hashlib.sha1(value.encode("utf-8")).hexdigest()[:HASH_LEN]

    parts = value.split("-")
    if len(parts) == 1:
        keep = max_len - HASH_LEN - 1
        trimmed = value[:keep].rstrip("-")
        return f"{trimmed}-{digest}"

    first = parts[0]
    rest = "-".join(parts[1:])
    available_for_rest = max_len - len(first) - HASH_LEN - 2

    if available_for_rest < 6:
        keep = max_len - HASH_LEN - 1
        trimmed = value[:keep].rstrip("-")
        return f"{trimmed}-{digest}"

    fragment = rest[:available_for_rest].rstrip("-")
    return f"{first}-{fragment}-{digest}"


def normalize_top_level_key(value: str) -> str:
    value = normalize_name(value)

    if not value:
        return value

    base, suffix = split_timing_suffix(value)

    if suffix:
        reordered = f"{suffix}-{base}" if base else suffix
    else:
        reordered = value

    return shorten_with_hash(reordered, TOP_LEVEL_KEY_MAX_LEN)


def normalize_annotations(rule):
    if not isinstance(rule, dict):
        return rule

    annotations = rule.get("annotations")
    if isinstance(annotations, dict):
        for key, value in list(annotations.items()):
            annotations[key] = normalize_multiline_to_escaped_string(value)

    return rule


def normalize_rule(rule):
    if not isinstance(rule, dict):
        return rule

    rule = copy.deepcopy(rule)

    if "expr" in rule:
        rule["expr"] = clean_expr(rule["expr"])

    labels = rule.get("labels")
    if isinstance(labels, dict):
        if "group_name" in labels and isinstance(labels["group_name"], str):
            labels["group_name"] = normalize_name(labels["group_name"])

    rule = normalize_annotations(rule)
    return rule


def normalize_groups(rule_def):
    if not isinstance(rule_def, dict):
        return rule_def

    rule_def = copy.deepcopy(rule_def)
    groups = rule_def.get("groups")

    if not isinstance(groups, list):
        return rule_def

    for group in groups:
        if not isinstance(group, dict):
            continue

        if "name" in group and isinstance(group["name"], str):
            group["name"] = normalize_name(group["name"])

        rules = group.get("rules")
        if not isinstance(rules, list):
            continue

        for i, rule in enumerate(rules):
            rules[i] = normalize_rule(rule)

    return rule_def


def choose_key_source(original_key, value):
    """
    Prefer a shorter, more meaningful source for the top-level key:
    1. first rules[].record
    2. otherwise first rules[].alert
    3. otherwise original top-level key
    """
    if isinstance(value, dict):
        groups = value.get("groups")
        if isinstance(groups, list):
            for group in groups:
                if not isinstance(group, dict):
                    continue
                rules = group.get("rules")
                if not isinstance(rules, list):
                    continue

                for rule in rules:
                    if isinstance(rule, dict):
                        record = rule.get("record")
                        if isinstance(record, str) and record.strip():
                            return record

            for group in groups:
                if not isinstance(group, dict):
                    continue
                rules = group.get("rules")
                if not isinstance(rules, list):
                    continue

                for rule in rules:
                    if isinstance(rule, dict):
                        alert = rule.get("alert")
                        if isinstance(alert, str) and alert.strip():
                            return alert

    return original_key


def merge_additional_prometheus_rules(yaml_files):
    combined = {}
    duplicates = []
    key_sources = {}

    for file_path in yaml_files:
        data = load_yaml_file(file_path)
        if data is None:
            continue

        rules_map = data.get("additionalPrometheusRulesMap")
        if not rules_map:
            continue

        if not isinstance(rules_map, dict):
            print(
                f"WARNING: 'additionalPrometheusRulesMap' is not a mapping in {file_path}, skipping",
                file=sys.stderr,
            )
            continue

        for original_key, value in rules_map.items():
            key_source = choose_key_source(original_key, value)
            normalized_key = normalize_top_level_key(key_source)
            normalized_value = normalize_groups(value)

            if normalized_key in combined:
                first_file = key_sources[normalized_key]
                duplicates.append((normalized_key, str(first_file), str(file_path)))
                print(
                    f"WARNING: Duplicate key '{normalized_key}' found.\n"
                    f"  First file:  {first_file}\n"
                    f"  Second file: {file_path}\n"
                    f"  Key source used: {key_source}\n"
                    f"  Overwriting previous definition.",
                    file=sys.stderr,
                )
            else:
                key_sources[normalized_key] = file_path

            combined[normalized_key] = normalized_value

    return {"additionalPrometheusRulesMap": combined}, duplicates


def write_yaml_file(output_path: Path, data):
    try:
        with output_path.open("w", encoding="utf-8") as f:
            yaml.dump(data, f)
    except Exception as e:
        print(f"ERROR: Failed to write output file {output_path}: {e}", file=sys.stderr)
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="Combine additionalPrometheusRulesMap YAML from multiple nested directories into one file."
    )
    parser.add_argument(
        "roots",
        nargs="+",
        help="One or more root directories to search recursively",
    )
    parser.add_argument(
        "-o",
        "--output",
        required=True,
        help="Output YAML file path",
    )

    args = parser.parse_args()

    yaml_files = find_yaml_files(args.roots)
    if not yaml_files:
        print("No YAML files found.", file=sys.stderr)
        sys.exit(1)

    merged_data, duplicates = merge_additional_prometheus_rules(yaml_files)
    write_yaml_file(Path(args.output), merged_data)

    print(f"Processed {len(yaml_files)} YAML files.")
    print(f"Wrote merged output to: {args.output}")

    if duplicates:
        print(f"Found {len(duplicates)} duplicate key(s). See warnings above.", file=sys.stderr)


if __name__ == "__main__":
    main()
