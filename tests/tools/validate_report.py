#!/usr/bin/env python3
"""Validate a qvk JSON report against schema/report.schema.json.

Stdlib only (no `jsonschema` package), so CI never downloads anything.
Supports exactly the JSON Schema subset used by report.schema.json:
$ref (local #/$defs/...), type, enum, const, required, properties,
additionalProperties (bool or schema), items, pattern, minLength, minimum.

Usage: validate_report.py [--schema PATH] REPORT.json [REPORT.json ...]
Exit: 0 all valid, 1 validation errors, 2 usage / unreadable input.
"""

import json
import re
import sys
from pathlib import Path

SUPPORTED = {
    "$schema", "$id", "$defs", "$ref", "title", "description", "type", "enum", "const",
    "required", "properties", "additionalProperties", "items", "pattern", "minLength", "minimum",
}


def type_ok(value, name):
    if name == "null":
        return value is None
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "string":
        return isinstance(value, str)
    if name == "array":
        return isinstance(value, list)
    if name == "object":
        return isinstance(value, dict)
    raise ValueError(f"unsupported type {name!r}")


class Validator:
    def __init__(self, root):
        self.root = root
        self.errors = []

    def resolve(self, ref):
        if not ref.startswith("#/"):
            raise ValueError(f"only local refs are supported: {ref}")
        node = self.root
        for part in ref[2:].split("/"):
            node = node[part]
        return node

    def check(self, value, schema, path="$"):
        unknown = set(schema) - SUPPORTED
        if unknown:
            raise ValueError(f"{path}: unsupported schema keywords {sorted(unknown)}")
        if "$ref" in schema:
            self.check(value, self.resolve(schema["$ref"]), path)
        if "type" in schema:
            types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(type_ok(value, t) for t in types):
                self.errors.append(f"{path}: expected {'/'.join(types)}, got {json.dumps(value)[:60]}")
                return
        if "const" in schema and value != schema["const"]:
            self.errors.append(f"{path}: expected {schema['const']!r}, got {value!r}")
        if "enum" in schema and not any(value == e and type(value) is type(e) for e in schema["enum"]):
            self.errors.append(f"{path}: {value!r} not in {schema['enum']}")
        if isinstance(value, str):
            if "minLength" in schema and len(value) < schema["minLength"]:
                self.errors.append(f"{path}: shorter than {schema['minLength']}")
            if "pattern" in schema and not re.search(schema["pattern"], value):
                self.errors.append(f"{path}: {value!r} does not match {schema['pattern']}")
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            if "minimum" in schema and value < schema["minimum"]:
                self.errors.append(f"{path}: {value} < minimum {schema['minimum']}")
        if isinstance(value, dict):
            for key in schema.get("required", []):
                if key not in value:
                    self.errors.append(f"{path}: missing required key {key!r}")
            props = schema.get("properties", {})
            extra = schema.get("additionalProperties", True)
            for key, item in value.items():
                if key in props:
                    self.check(item, props[key], f"{path}.{key}")
                elif extra is False:
                    self.errors.append(f"{path}: unexpected key {key!r}")
                elif isinstance(extra, dict):
                    self.check(item, extra, f"{path}.{key}")
        if isinstance(value, list) and "items" in schema:
            for i, item in enumerate(value):
                self.check(item, schema["items"], f"{path}[{i}]")


def reject_constants(text):
    raise ValueError(f"non-standard JSON constant {text}")


def main(argv):
    schema_path = Path(__file__).resolve().parents[2] / "schema" / "report.schema.json"
    args = list(argv)
    if len(args) >= 2 and args[0] == "--schema":
        schema_path = Path(args[1])
        args = args[2:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    status = 0
    for name in args:
        try:
            raw = Path(name).read_bytes() if name != "-" else sys.stdin.buffer.read()
            report = json.loads(raw.decode("utf-8"), parse_constant=reject_constants)
        except (OSError, UnicodeDecodeError, ValueError) as exc:
            print(f"{name}: unreadable or invalid JSON: {exc}", file=sys.stderr)
            return 2
        validator = Validator(schema)
        validator.check(report, schema)
        if validator.errors:
            status = 1
            for err in validator.errors:
                print(f"{name}: {err}", file=sys.stderr)
        else:
            print(f"{name}: valid")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
