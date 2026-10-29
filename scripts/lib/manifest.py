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
    manifest.py <env> --consumer terraform
                                         Only rows Terraform reads through a
                                         data source (GoGo-Infra#194). Rendered
                                         by nothing; no env_var, emitted as "-"
    manifest.py <env> --consumer all     Every consumer
    manifest.py <env> --include-parked   Widen a parameter listing to rows whose
                                         `lifecycle: parked` (GoGo-Infra#308).
                                         Parked rows are emitted by nothing
                                         otherwise, for any environment
    manifest.py <env> --retired          Rows of the `retired:` block that apply
                                         to the env's trees: "path<TAB>namespace<TAB>since".
                                         A retired row must be absent from SSM
    manifest.py <env> --capabilities     Capabilities enabled in that env:
                                         "name<TAB>kind<TAB>state"
    manifest.py <env> --capability-requires
                                         Credentials each needs:
                                         "name<TAB>namespace<TAB>path"
    manifest.py <env> --include-planned   Widen either of the two above from
                                         `enabled` to `enabled + planned`, i.e.
                                         what the environment is intended to run
                                         (with --include-parked: also the
                                         capabilities a parked row has parked,
                                         state "parked")
    manifest.py <env> --check            Exit 0 when the manifest is consistent, 2
                                         (with the contradictions on stderr) when it
                                         is not. Callers run it once, up front: the
                                         check is global, so a manifest that passes
                                         it passes every later call in the same run,
                                         and a row stream read through process
                                         substitution — whose exit status bash
                                         discards — can never be the empty answer
                                         of a refused manifest (Sol F-01, #308)
    manifest.py <env> --field <name>     Append one extra field to each row, so a
                                         caller can read `scope`, `provider`,
                                         `infra_readable` or `lifecycle` without
                                         a YAML parser

`<env>` is dev, stag or prod — or `tools` (GoGo-Infra#294), the
pseudo-environment of the developer-tooling keys under /gogo/tools/. The
`tools` namespace belongs to `tools` alone: a real environment is never handed
a tools row, whatever filter it asks for, and `tools` is handed nothing else.
That is what keeps the agent App key and the harness's provider keys out of
every environment's validation, rendering and parity — one rule here instead
of one filter in each caller.

Row lifecycle (GoGo-Infra#308). A row is `active` unless it says
`lifecycle: parked`: declared for no environment until its feature is
scheduled, so no listing emits it, nothing validates, writes or renders it, and
a capability that `requires:` one is parked with it. A row that must be absent
is not a row: it is an entry of the top-level `retired:` block, and
`validate.sh` fails when SSM still holds it. `environments:` on a row names
the environments in which it is declared at all (default: every one); the
reader emits the row for no other environment, so it can be neither missing
nor absent there — stored there anyway, it is undeclared.

Namespace defaults to `backend` (`tools` for `tools`) and consumer defaults to `runtime`. Both
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

ENVIRONMENTS = ("dev", "stag", "prod")
LIFECYCLES = ("active", "parked")


class ManifestError(Exception):
    """The manifest contradicts itself. Reported, exit 2 — never guessed around."""


# A folded scalar (`key: >-`) continues on indented lines. The parser keeps only
# the first line's text, which is enough for every field it is asked about and
# avoids pulling in a YAML dependency for prose nobody parses.
def _list(raw):
    return [x.strip() for x in raw.strip("[]").split(",") if x.strip()]


def parse(section="parameters"):
    """Rows of one top-level list. `parameters` by default; `capabilities` for
    the credential groups, `retired` for the rows that must be absent. All have
    the same flat shape, so one parser serves."""
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
        # Absent means every environment; the ci namespace follows the same
        # list (its tree is /gogo/ci/<env>/). Tools rows carry none: `tools`
        # is not an environment and the tools rule below is what scopes them.
        entry["environments_list"] = (
            _list(entry["environments"]) if "environments" in entry else list(ENVIRONMENTS)
        )
        entry["lifecycle"] = entry.get("lifecycle", "") or "active"

    if section == "parameters":
        check(entries)
    return entries


def check(entries):
    """Contradictions that would otherwise be silently resolved by whichever
    caller read the row first. `environments:` and `lifecycle:` are new shape
    (GoGo-Infra#308), and a misspelt value in either would quietly widen or
    narrow what an environment is validated against."""
    problems = []
    for entry in entries:
        key = f"{entry.get('namespace', 'backend')}:{entry.get('path', '?')}"
        if entry["lifecycle"] not in LIFECYCLES:
            problems.append(f"{key}: lifecycle must be one of {', '.join(LIFECYCLES)} (got '{entry['lifecycle']}')")
        unknown = [e for e in entry["environments_list"] if e not in ENVIRONMENTS]
        if unknown:
            problems.append(f"{key}: environments names no environment: {', '.join(unknown)}")
        if entry.get("namespace", "backend") == "tools" and "environments" in entry:
            problems.append(f"{key}: a tools row belongs to no environment and cannot carry environments:")
        outside = [e for e in entry["required_list"] if e not in entry["environments_list"]]
        if outside:
            problems.append(
                f"{key}: required in {', '.join(outside)} but declared only in {', '.join(entry['environments_list'])}"
            )
    declared = {f"{e.get('namespace', 'backend')}:{e.get('path')}" for e in entries}
    for row in parse("retired"):
        key = f"{row.get('namespace', 'backend')}:{row.get('path', '?')}"
        if key in declared:
            problems.append(f"{key}: listed under retired: and still declared under parameters:")
        if row.get("namespace", "backend") not in ("backend", "mobile", "ci", "tools"):
            problems.append(f"{key}: retired row in an unknown namespace")
    if problems:
        raise ManifestError("\n".join(problems))


def parked_keys():
    """`namespace:path` of every parked row, whatever the environment."""
    return {
        f"{e.get('namespace', 'backend')}:{e['path']}"
        for e in parse()
        if e["lifecycle"] == "parked"
    }


def capabilities(env, include_planned=False, include_parked=False):
    """Capabilities this environment runs, or intends to.

    `enabled` is what runs today; `planned` is what the environment is meant to
    run and has not been provisioned for. Readiness widens to include `planned`
    on request, which is how a new environment is brought up: the check names
    every credential to create instead of anyone re-reading the workflows.

    A capability that requires a parked row is parked with it (GoGo-Infra#308):
    its credentials are declared for no environment, so readiness cannot
    demand them. It is omitted unless `include_parked`, which lists it with
    state `parked` for a report, never for enforcement.
    """
    parked = parked_keys()
    out = []
    for cap in parse("capabilities"):
        if env in cap["enabled_list"]:
            cap["state"] = "enabled"
        elif include_planned and env in cap["planned_list"]:
            cap["state"] = "planned"
        else:
            continue
        if any(":".join(split_requirement(r)) in parked for r in cap["requires_list"]):
            if not include_parked:
                continue
            cap["state"] = "parked"
        out.append(cap)
    return out


def declares(env):
    """Whether any capability mentions this environment at all.

    An environment named nowhere has no intended shape, so nothing can say it is
    ready. Reporting READY because a profile was omitted is the same failure as
    reporting it because a namespace could not be read. A parked capability
    mentions nothing: it is declared for no environment.
    """
    parked = parked_keys()
    return any(
        (env in cap["enabled_list"] or env in cap["planned_list"])
        and not any(":".join(split_requirement(r)) in parked for r in cap["requires_list"])
        for cap in parse("capabilities")
    )


def split_requirement(entry):
    """`namespace:path`, defaulting to backend."""
    if ":" in entry:
        namespace, path = entry.split(":", 1)
        return namespace.strip(), path.strip()
    return "backend", entry.strip()


def declared_in(entry, env):
    """Whether the row exists for this environment at all.

    The tools namespace and the tools pseudo-environment imply each other
    (module docstring). `ci` is the env-less pipeline tree put.sh/get.sh pass
    through to resolve a namespace, not an environment: every non-tools row
    answers it. A real environment sees a row only when `environments:` names
    it (GoGo-Infra#308).
    """
    if (entry.get("namespace", "backend") == "tools") != (env == "tools"):
        return False
    if env in ("tools", "ci"):
        return True
    return env in entry["environments_list"]


def main():
    if len(sys.argv) < 2:
        sys.stderr.write(__doc__)
        return 2

    env = sys.argv[1]
    # GoGo-Infra#286 (ADR-0015). Any other word would match no row and answer
    # "nothing required" with exit 0, which reads like a real answer. `ci` is
    # not an environment but the env-less pipeline tree (/gogo/ci, see
    # ssm_prefix and `require_env_arg … allow-ci`): put.sh/get.sh/delete.sh pass
    # it through to resolve a row's namespace, and must keep working (Sol F-06).
    # `tools` (GoGo-Infra#294) is the other env-less tree, /gogo/tools/.
    if env not in ("dev", "stag", "prod", "ci", "tools"):
        sys.stderr.write(f"error: environment must be one of: dev, stag, prod (got '{env}')\n")
        return 2
    args = sys.argv[2:]
    required_only = "--required" in args

    # Feature queries answer a different question and return a different shape,
    # so they short-circuit before the parameter filters below.
    include_planned = "--include-planned" in args
    include_parked = "--include-parked" in args

    try:
        if "--capabilities" in args:
            for cap in capabilities(env, include_planned, include_parked):
                sys.stdout.write(
                    "\t".join([cap["name"], cap.get("kind", "feature"), cap["state"]]) + "\n"
                )
            return 0

        if "--capability-requires" in args:
            for cap in capabilities(env, include_planned, include_parked):
                for requirement in cap["requires_list"]:
                    namespace, path = split_requirement(requirement)
                    sys.stdout.write("\t".join([cap["name"], namespace, path]) + "\n")
            return 0

        if "--check" in args:
            parse()
            parse("retired")
            return 0

        if "--declares" in args:
            # Exit status only: 0 when the environment has a profile, 1 when it does
            # not. Shell callers should not have to parse prose for this.
            return 0 if declares(env) else 1

        if "--retired" in args:
            parse()  # the consistency check runs on the parameters block
            for row in parse("retired"):
                if (row.get("namespace", "backend") == "tools") != (env == "tools"):
                    continue
                sys.stdout.write(
                    "\t".join([row["path"], row.get("namespace", "backend"), row.get("since", "") or "-"]) + "\n"
                )
            return 0

        extra_field = ""
        if "--field" in args:
            index = args.index("--field")
            if index + 1 >= len(args):
                sys.stderr.write("--field needs a field name, e.g. scope, provider or lifecycle\n")
                return 2
            extra_field = args[index + 1]

        namespace = "tools" if env == "tools" else "backend"
        if "--namespace" in args:
            index = args.index("--namespace")
            if index + 1 >= len(args):
                sys.stderr.write("--namespace needs a value: backend, mobile, ci, tools, or all\n")
                return 2
            namespace = args[index + 1]

        consumer = "runtime"
        if "--consumer" in args:
            index = args.index("--consumer")
            if index + 1 >= len(args):
                sys.stderr.write(
                    "--consumer needs a value: runtime, seed, observability, pipeline, terraform, or all\n"
                )
                return 2
            consumer = args[index + 1]

        for entry in parse():
            # Before every other filter, so no flag widens either: the tools
            # rule and `environments:` decide whether the row exists here at
            # all, and a parked row exists nowhere unless a report asks.
            if not declared_in(entry, env):
                continue
            if entry["lifecycle"] == "parked" and not include_parked:
                continue
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
                # `--field lifecycle` prints active or parked; every other
                # field prints what was written, empty when nothing was.
                columns.append(entry.get(extra_field, ""))
            sys.stdout.write("\t".join(columns) + "\n")
        return 0
    except ManifestError as error:
        sys.stderr.write(f"error: config/secrets.manifest.yml contradicts itself:\n{error}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main())
