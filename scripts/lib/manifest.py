#!/usr/bin/env python3
"""Read secrets.manifest.yaml without a YAML dependency.

The manifest has a deliberately fixed shape (a `parameters:` list of flat
mappings), so a full YAML parser is not needed and not assumed to be installed
on a developer machine or a CI runner.

Usage:
    manifest.py <env>                    Emit "path<TAB>env_var<TAB>type<TAB>required<TAB>namespace<TAB>consumer"
    manifest.py <env> --required         Only the parameters required in that env
    manifest.py <env> --namespace mobile Only that namespace
    manifest.py <env> --namespace all    Every namespace
    manifest.py <env> --consumer seed    Only rows a seed/provisioning command loads
    manifest.py <env> --consumer all     Every consumer

Namespace defaults to `backend` and consumer defaults to `runtime`. Both
defaults are load-bearing rather than convenient: render-env.sh renders every
row it is given into the API's runtime env file, so a caller written before
either field existed must keep receiving exactly the rows it was written to
render.

The two filters answer different questions and neither substitutes for the
other. Namespace is *where the value lives* — it picks the SSM prefix, and a
client key that leaked into the backend default would be handed to the server
under a path the server cannot even read. Consumer is *which process loads it*
— a CMS bootstrap password belongs under `backend` (same prefix, same IAM) and
still has no business in the environment of an internet-facing API.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(ROOT, "config", "secrets.manifest.yml")

FIELD = re.compile(r"^\s{4}([a-z_]+):\s*(.*)$")
ITEM = re.compile(r"^\s{2}-\s+([a-z_]+):\s*(.*)$")


def parse():
    entries = []
    current = None
    in_parameters = False

    with open(MANIFEST, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue

            if line.startswith("parameters:"):
                in_parameters = True
                continue

            if not in_parameters:
                continue

            item = ITEM.match(line)
            if item:
                if current:
                    entries.append(current)
                current = {item.group(1): item.group(2).strip()}
                continue

            field = FIELD.match(line)
            if field and current is not None:
                current[field.group(1)] = field.group(2).strip()

    if current:
        entries.append(current)

    for entry in entries:
        required = entry.get("required", "[]").strip("[]")
        entry["required_list"] = [x.strip() for x in required.split(",") if x.strip()]

    return entries


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    env = sys.argv[1]
    args = sys.argv[2:]
    required_only = "--required" in args

    namespace = "backend"
    if "--namespace" in args:
        index = args.index("--namespace")
        if index + 1 >= len(args):
            sys.stderr.write("--namespace needs a value: backend, mobile, or all\n")
            return 2
        namespace = args[index + 1]

    consumer = "runtime"
    if "--consumer" in args:
        index = args.index("--consumer")
        if index + 1 >= len(args):
            sys.stderr.write("--consumer needs a value: runtime, seed, or all\n")
            return 2
        consumer = args[index + 1]

    for entry in parse():
        if required_only and env not in entry["required_list"]:
            continue
        if namespace != "all" and entry.get("namespace", "backend") != namespace:
            continue
        if consumer != "all" and entry.get("consumer", "runtime") != consumer:
            continue
        sys.stdout.write(
            "\t".join(
                [
                    entry["path"],
                    entry.get("env_var", ""),
                    entry.get("type", "SecureString"),
                    ",".join(entry["required_list"]),
                    entry.get("namespace", "backend"),
                    entry.get("consumer", "runtime"),
                ]
            )
            + "\n"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
