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
    manifest.py <env> --capabilities     Capabilities enabled in that env:
                                         "name<TAB>kind<TAB>state"
    manifest.py <env> --capability-requires
                                         Credentials each needs:
                                         "name<TAB>namespace<TAB>path"
    manifest.py <env> --include-planned   Widen either of the two above from
                                         `enabled` to `enabled + planned`, i.e.
                                         what the environment is intended to run
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
        entry["planned_list"] = _list(entry.get("planned", "[]"))
        entry["requires_list"] = _list(entry.get("requires", "[]"))

    return entries


def capabilities(env, include_planned=False):
    """Capabilities this environment runs, or intends to.

    `enabled` is what runs today; `planned` is what the environment is meant to
    run and has not been provisioned for. Readiness widens to include `planned`
    on request, which is how a new environment is brought up: the check names
    every credential to create instead of anyone re-reading the workflows.
    """
    out = []
    for cap in parse("capabilities"):
        if env in cap["enabled_list"]:
            cap["state"] = "enabled"
        elif include_planned and env in cap["planned_list"]:
            cap["state"] = "planned"
        else:
            continue
        out.append(cap)
    return out


def declares(env):
    """Whether any capability mentions this environment at all.

    An environment named nowhere has no intended shape, so nothing can say it is
    ready. Reporting READY because a profile was omitted is the same failure as
    reporting it because a namespace could not be read.
    """
    return any(
        env in cap["enabled_list"] or env in cap["planned_list"]
        for cap in parse("capabilities")
    )


def split_requirement(entry):
    """`namespace:path`, defaulting to backend."""
    if ":" in entry:
        namespace, path = entry.split(":", 1)
        return namespace.strip(), path.strip()
    return "backend", entry.strip()


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    env = sys.argv[1]
    args = sys.argv[2:]
    required_only = "--required" in args

    # Feature queries answer a different question and return a different shape,
    # so they short-circuit before the parameter filters below.
    include_planned = "--include-planned" in args

    if "--capabilities" in args:
        for cap in capabilities(env, include_planned):
            sys.stdout.write(
                "\t".join([cap["name"], cap.get("kind", "feature"), cap["state"]]) + "\n"
            )
        return 0

    if "--capability-requires" in args:
        for cap in capabilities(env, include_planned):
            for requirement in cap["requires_list"]:
                namespace, path = split_requirement(requirement)
                sys.stdout.write("\t".join([cap["name"], namespace, path]) + "\n")
        return 0

    if "--declares" in args:
        # Exit status only: 0 when the environment has a profile, 1 when it does
        # not. Shell callers should not have to parse prose for this.
        return 0 if declares(env) else 1

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
