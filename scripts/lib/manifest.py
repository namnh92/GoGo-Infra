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
    manifest.py <env> --consumer observability
                                         Only rows the observability host loads
    manifest.py <env> --consumer pipeline
                                         Only rows a CI job loads
    manifest.py <env> --consumer all     Every consumer
    manifest.py <env> --features         Features enabled in that env, one per line
    manifest.py <env> --feature-requires Paths every enabled feature needs:
                                         "feature<TAB>path"
    manifest.py <env> --field <name>     Append one extra field to each row, so a
                                         caller can read `scope` or `provider`
                                         without a YAML parser

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

# A folded scalar (`key: >-`) continues on indented lines. The parser keeps only
# the first line's text, which is enough for every field it is asked about and
# avoids pulling in a YAML dependency for prose nobody parses.
def _list(raw):
    return [x.strip() for x in raw.strip("[]").split(",") if x.strip()]


def parse(section="parameters"):
    """Rows of one top-level list. `parameters` by default; `features` for the
    prerequisite groups. Both have the same flat shape, so one parser serves."""
    entries = []
    current = None
    in_parameters = False

    with open(MANIFEST, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue

            if re.match(r"^[a-z_]+:", line):
                in_parameters = line.startswith(section + ":")
                if in_parameters:
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
        entry["required_list"] = _list(entry.get("required", "[]"))
        entry["enabled_list"] = _list(entry.get("enabled", "[]"))
        entry["requires_list"] = _list(entry.get("requires", "[]"))

    return entries


def enabled_features(env):
    """Features switched on in this environment, with their prerequisites."""
    return [f for f in parse("features") if env in f["enabled_list"]]


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    env = sys.argv[1]
    args = sys.argv[2:]
    required_only = "--required" in args

    # Feature queries answer a different question and return a different shape,
    # so they short-circuit before the parameter filters below.
    if "--features" in args:
        for feature in enabled_features(env):
            sys.stdout.write(feature["name"] + "\n")
        return 0

    if "--feature-requires" in args:
        for feature in enabled_features(env):
            for path in feature["requires_list"]:
                sys.stdout.write(feature["name"] + "\t" + path + "\n")
        return 0

    extra_field = ""
    if "--field" in args:
        index = args.index("--field")
        if index + 1 >= len(args):
            sys.stderr.write("--field needs a field name, e.g. scope or provider\n")
            return 2
        extra_field = args[index + 1]

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
            sys.stderr.write(
                "--consumer needs a value: runtime, seed, observability, pipeline, or all\n"
            )
            return 2
        consumer = args[index + 1]

    for entry in parse():
        if required_only and env not in entry["required_list"]:
            continue
        if namespace != "all" and entry.get("namespace", "backend") != namespace:
            continue
        if consumer != "all" and entry.get("consumer", "runtime") != consumer:
            continue
        # Column order is a contract: render-env.sh and pull.sh read these
        # positionally. New fields are appended behind --field, never inserted.
        columns = [
            entry["path"],
            # "-" rather than "": bash treats tab as IFS *whitespace*, so a run
            # of tabs collapses into one delimiter and an empty field shifts
            # every column after it. `read -r path env_var type required` then
            # silently puts the type in `env_var`. A placeholder keeps the
            # positions a contract, which is what every caller assumes.
            entry.get("env_var", "") or "-",
            entry.get("type", "SecureString"),
            ",".join(entry["required_list"]),
            entry.get("namespace", "backend"),
            entry.get("consumer", "runtime"),
        ]
        if extra_field:
            columns.append(entry.get(extra_field, ""))
        sys.stdout.write("\t".join(columns) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
