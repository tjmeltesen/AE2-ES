#!/usr/bin/env python3
"""Generate an ae2es_broker.cfg Lua data table from its YAML descriptor."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import yaml


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DESCRIPTOR = PROJECT_ROOT / "config-descriptor.yml"
DEFAULT_OUTPUT = PROJECT_ROOT / "ae2es_broker.cfg"


def lua_literal(value: Any, indent: int = 0) -> str:
    """Serialize YAML-compatible values as ConfigUI-loadable Lua literals."""
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("Lua configuration values must be finite numbers")
        return format(value, ".15g")
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)

    child_indent = " " * (indent + 2)
    current_indent = " " * indent
    if isinstance(value, list):
        if not value:
            return "{}"
        values = ",\n".join(
            f"{child_indent}{lua_literal(item, indent + 2)}" for item in value
        )
        return "{\n" + values + f",\n{current_indent}}}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        entries = []
        for key in sorted(value, key=str):
            if not isinstance(key, str):
                raise ValueError("Lua configuration map keys must be strings")
            entries.append(
                f"{child_indent}[{json.dumps(key, ensure_ascii=False)}] = "
                f"{lua_literal(value[key], indent + 2)}"
            )
        return "{\n" + ",\n".join(entries) + f",\n{current_indent}}}"

    raise ValueError(f"Unsupported configuration value type: {type(value).__name__}")


def load_descriptor(path: Path) -> dict[str, dict[str, Any]]:
    """Load and minimally validate the persisted ConfigUI field schema."""
    with path.open(encoding="utf-8") as descriptor_file:
        descriptor = yaml.safe_load(descriptor_file)

    if not isinstance(descriptor, dict) or not isinstance(descriptor.get("fields"), dict):
        raise ValueError("Descriptor must contain a 'fields' mapping")

    fields = descriptor["fields"]
    for name, field in fields.items():
        if not isinstance(name, str) or not isinstance(field, dict) or "default" not in field:
            raise ValueError(f"Field {name!r} must define a default value")
    return fields


def render_config(fields: dict[str, dict[str, Any]]) -> str:
    """Render defaults as the Lua table ConfigUI.loadConfig expects."""
    lines = [
        "return {",
        "  -- AE2-ES Exec Broker Config",
        "  -- Generated from config-descriptor.yml; edit the descriptor, then regenerate.",
    ]
    for name, field in fields.items():
        lines.append(f"  {name} = {lua_literal(field['default'], 2)},")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--descriptor",
        type=Path,
        default=DEFAULT_DESCRIPTOR,
        help=f"YAML descriptor path (default: {DEFAULT_DESCRIPTOR})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Lua config output path (default: {DEFAULT_OUTPUT})",
    )
    arguments = parser.parse_args()

    try:
        fields = load_descriptor(arguments.descriptor)
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(render_config(fields), encoding="utf-8")
    except (OSError, ValueError, yaml.YAMLError) as error:
        parser.error(str(error))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
