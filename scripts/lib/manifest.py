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
    manifest.py <env> --all-namespaces   Sorted namespace names across all rows,
                                         including parked and retired, ignoring
                                         environments: and consumer filters;
                                         the tools-only boundary still applies
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
    manifest.py <env> --destination-lifecycle <name>
                                         Print parked/retired for a full SSM name;
                                         empty if writable, independent of <env>.

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
                                         A requirement on a parked row keeps
                                         the capability's state; validate.sh
                                         reports it as a parked dependency
    manifest.py <env> --check            Exit 0 when the manifest is consistent, 2
                                         (with the contradictions on stderr) when it
                                         is not. Callers run it once, up front: the
                                         check is global, so a manifest that passes
                                         it passes every later call in the same run,
                                         and a row stream read through process
                                         substitution — whose exit status bash
                                         discards — can never be the empty answer
                                         of a refused manifest (Sol F-01, #308)
    manifest.py <env> --report-build --facts <file> --out <report.json>
                [--strict] [--include-planned] [--validator-status <n>]
                                         The secrets readiness report
                                         (GoGo-Infra#309, ADR-0016) from the
                                         facts validate.sh collected. Exit
                                         0/1/2 = verdict OK/FAIL/UNKNOWN.
                                         validate.sh --report is the caller
    manifest.py <env> --report-aborted <report.json> --reason <text>
                                         The report of a run that stopped
                                         before its facts were complete (exit 2)
    manifest.py <env> --summary <report.json>
                                         Markdown run summary: one line per
                                         capability, then the core group
    manifest.py <env> --project-deploy <report.json> --release-sha <sha> --run-id <id> --run-attempt <n>
                                         The backend runtime projection a
                                         deploy leaves on the host (D-6-B)
    manifest.py <env> --validator-classes
                                         validate.sh's class headings and the
                                         report code of each
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
scheduled, so no listing emits it, nothing validates, writes or renders it. A
capability that `requires:` one keeps its enabled/planned state and is reported
not ready by validate.sh (a parked dependency). A row that must be absent
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


class ReportError(Exception):
    """A readiness report, facts file or argument this reader refuses. Exit 2."""


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
        if entry["lifecycle"] == "parked" and entry["required_list"]:
            # A parked row is declared for no environment, so a requirement on
            # it would be dropped without a word (Astra residual, #308).
            problems.append(f"{key}: parked but required in {', '.join(entry['required_list'])}")
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


def capabilities(env, include_planned=False):
    """Capabilities this environment runs, or intends to.

    `enabled` is what runs today; `planned` is what the environment is meant to
    run and has not been provisioned for. Readiness widens to include `planned`
    on request, which is how a new environment is brought up: the check names
    every credential to create instead of anyone re-reading the workflows.

    A requirement on a parked row does not change the capability's state
    (Astra A-F-01, #308; #309 D-1): intent stays `enabled`/`planned`, and the
    capability is simply not ready — validate.sh names the dependency as
    parked. Parking a row never switches a capability off by itself.
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


def destination_lifecycle(name):
    """Match SSM names, not suffixes: the ci selector can carry an env prefix."""
    def names(row, retired=False):
        namespace = row.get("namespace", "backend")
        if namespace == "tools":
            return {"/gogo/tools/" + row["path"]}
        environments = ENVIRONMENTS if retired else row["environments_list"]
        return {
            (f"/gogo/ci/{env}/" if namespace == "ci" else f"/gogo/{env}/{namespace}/")
            + row["path"] for env in environments
        }

    rows = parse()
    # Only an active declaration at this exact destination takes precedence.
    if any(row["lifecycle"] == "active" and name in names(row) for row in rows):
        return ""
    if any(row["lifecycle"] == "parked" and name in names(row) for row in rows):
        return "parked"
    if any(name in names(row, retired=True) for row in parse("retired")):
        return "retired"
    return ""


# ── Secrets readiness report (GoGo-Infra#309, ADR-0016) ─────────────────────
#
# validate.sh is the collector and the classifier: it lists SSM, prints the
# classes, and records what it saw in a facts file — names, types, dates and the
# class of every name it printed. Nothing here reads a value, a length or a
# hash: SSM metadata is all the facts file can hold. This turns those facts into
# the versioned report and owns the one aggregation (D-1): row verdict,
# capability readiness, overall verdict. Every consumer — the run summary, the
# deploy projection, GoGo-BE, GoGo-CMS — displays these verdicts and computes
# none of its own (A-F-11).

REPORT_SCHEMA_VERSION = 1

# validate.sh's class headings and the code each one carries in the report.
# validate.test.sh pins this list against the headings validate.sh prints, so a
# new class is added here in the same change that adds it (A-F-08). MISSING is
# printed twice — required rows everywhere, and every declared tools row
# (#308: optional in the manifest, mandatory in the tools tree); the second is
# the tools form of declared-absent and is recorded as such.
VALIDATOR_CLASSES = (
    ("MISSING", "missing-required"),
    ("DECLARED, NOT STORED", "declared-absent"),
    ("UNDECLARED", "undeclared"),
    ("PARKED, STORED", "parked-present"),
    ("RETIRED, STILL STORED", "retired-present"),
    ("WRONG TYPE", "wrong-type"),
    ("INFRA-READABLE TAG MISSING", "tag-missing"),
    ("INFRA-READABLE TAG ON A SECRET OR UNDECLARED PARAMETER", "tag-misplaced"),
    ("CAPABILITY PREREQUISITES MISSING", "capability-not-ready"),
    ("NO CAPABILITY PROFILE", "no-capability-profile"),
    ("SKIPPED", "skipped"),
)

# Row findings that fail a row in every mode. declared-absent joins them under
# --strict and, for tools, always (validate.sh's own rule, #308).
ROW_FAILURES = (
    "missing-required",
    "wrong-type",
    "tag-missing",
    "tag-misplaced",
    "retired-present",
    "undeclared",
    "parked-present",
)
ROW_FINDINGS = ROW_FAILURES + ("declared-absent",)

# Why a capability is not ready. The first four make it FAIL, the last UNKNOWN.
DEPENDENCY_FINDINGS = (
    "dependency-missing",
    "dependency-parked",
    "dependency-planned",
    "dependency-invalid",
    "dependency-outside-environment",
    "dependency-unread",
)

# D-6-B: the only fields that leave GitHub for the deploy host (A-F-05).
PROJECTION_ROW_FIELDS = ("path", "env_var", "lifecycle", "presence", "findings", "verdict", "capabilities")
PROJECTION_CAPABILITY_FIELDS = ("name", "status", "verdict", "ready", "missing")


def ssm_prefix(env, namespace):
    """scripts/secrets/common.sh ssm_prefix, for the trees a report names."""
    if env == "tools" or namespace == "tools":
        return "/gogo/tools"
    if namespace == "ci":
        return f"/gogo/ci/{env}"
    return f"/gogo/{env}/{namespace}"


def namespace_of(env, name):
    """The namespace a full SSM name belongs to, for names no row declares."""
    if name.startswith("/gogo/tools/"):
        return "tools"
    if name.startswith(f"/gogo/ci/{env}/"):
        return "ci"
    parts = name.split("/")
    if len(parts) > 3 and parts[1] == "gogo" and parts[2] == env:
        return parts[3]
    return None


def manifest_sha():
    """Git blob id of the manifest: what `git rev-parse HEAD:config/secrets.manifest.yml`
    prints for a clean checkout, and still exact for an uncommitted edit."""
    import hashlib

    with open(MANIFEST, "rb") as handle:
        content = handle.read()
    return hashlib.sha1(b"blob %d\0" % len(content) + content).hexdigest()


def _now():
    import datetime

    return datetime.datetime.now(datetime.timezone.utc)


def _iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def _age_days(raw, now):
    """Days since SSM last modified the parameter. The update age, not rotation
    provenance (A-F-10): the #307 account copy reset every one of them."""
    import datetime

    if not raw or raw == "None":
        return None
    try:
        if re.fullmatch(r"[0-9]+(\.[0-9]+)?", raw):
            moment = datetime.datetime.fromtimestamp(float(raw), datetime.timezone.utc)
        else:
            moment = datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
            if moment.tzinfo is None:
                moment = moment.replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None
    return max(0, int((now - moment).total_seconds() // 86400))


def read_facts(path):
    """The facts file validate.sh writes: tab-separated, one observation a line."""
    facts = {"read": {}, "skipped": {}, "params": {}, "findings": {}, "classes": set(),
             "tags_skipped": None, "aborted": None}
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            cols = raw.rstrip("\n").split("\t")
            kind = cols[0]
            if kind == "namespace" and len(cols) >= 5:
                target = facts["read"] if cols[2] == "read" else facts["skipped"]
                target[cols[1]] = {"prefix": cols[3], "detail": cols[4]}
            elif kind == "param" and len(cols) >= 5:
                facts["params"][cols[2]] = {"namespace": cols[1], "type": cols[3], "modified": cols[4]}
            elif kind == "finding" and len(cols) >= 3:
                facts["findings"].setdefault(cols[2], set()).add(cols[1])
            elif kind == "class" and len(cols) >= 2:
                facts["classes"].add(cols[1])
            elif kind == "tags" and len(cols) >= 3:
                facts["tags_skipped"] = cols[2]
            elif kind == "aborted" and len(cols) >= 2:
                facts["aborted"] = cols[1]
    return facts


def _requirement_name(env, requirement):
    namespace, path = split_requirement(requirement)
    return namespace, f"{ssm_prefix(env, namespace)}/{path}"


def _verdict(parts):
    """FAIL > UNKNOWN > OK (A-F-08 r3)."""
    if "FAIL" in parts:
        return "FAIL"
    if "UNKNOWN" in parts:
        return "UNKNOWN"
    return "OK"


def build_report(env, facts, strict=False, include_planned=False, validator_status=None, now=None):
    """The D-1 report. `include_planned` is whether the operator asked for
    planned readiness (`--strict --include-planned`); planned capabilities are
    always reported, and drive the verdict only then (A-F-09)."""
    now = now or _now()
    tools = env == "tools"
    failing = set(ROW_FAILURES) | ({"declared-absent"} if strict or tools else set())

    caps = capabilities(env, include_planned=True)
    needed_by = {}
    for cap in caps:
        for requirement in cap["requires_list"]:
            _, name = _requirement_name(env, requirement)
            needed_by.setdefault(name, []).append(cap)

    rows = {}

    def presence(namespace, name):
        if namespace in facts["read"]:
            return "present" if name in facts["params"] else "absent"
        return "unknown"

    def add(name, namespace, lifecycle, entry=None):
        live = facts["params"].get(name)
        rows[name] = {
            "path": name,
            "namespace": namespace,
            "env_var": (entry.get("env_var") or None) if entry else None,
            "consumer": entry.get("consumer", "runtime") if entry else None,
            "type_declared": entry.get("type", "SecureString") if entry else None,
            "lifecycle": lifecycle,
            "presence": presence(namespace, name),
            "type_live": live["type"] if live else None,
            "findings": [],
            "parameter_age_days": _age_days(live["modified"], now) if live else None,
            "capabilities": sorted(c["name"] for c in needed_by.get(name, [])),
            "verified": "not-checked",
        }
        if rows[name]["env_var"] == "-":
            rows[name]["env_var"] = None

    for entry in parse():
        if not declared_in(entry, env):
            continue
        namespace = entry.get("namespace", "backend")
        name = f"{ssm_prefix(env, namespace)}/{entry['path']}"
        if entry["lifecycle"] == "parked":
            lifecycle = "parked"
        elif env in entry["required_list"]:
            lifecycle = "required"
        elif needed_by.get(name) and all(c["state"] == "planned" for c in needed_by[name]):
            lifecycle = "planned"
        else:
            lifecycle = "optional"
        add(name, namespace, lifecycle, entry)

    for row in parse("retired"):
        namespace = row.get("namespace", "backend")
        if (namespace == "tools") != tools:
            continue
        name = f"{ssm_prefix(env, namespace)}/{row['path']}"
        if name not in rows:
            add(name, namespace, "retired")

    for name, live in facts["params"].items():
        if name not in rows:
            add(name, live["namespace"], "undeclared")
    for name in facts["findings"]:
        if name not in rows:
            add(name, namespace_of(env, name) or "unknown", "undeclared")
            rows[name]["presence"] = "present"

    for name, codes in facts["findings"].items():
        rows[name]["findings"] = sorted(c for c in codes if c in ROW_FINDINGS)
    for row in rows.values():
        if any(f in failing for f in row["findings"]):
            row["verdict"] = "FAIL"
        elif row["presence"] == "unknown":
            row["verdict"] = "UNKNOWN"
        else:
            row["verdict"] = "OK"

    env_namespaces = {
        e.get("namespace", "backend") for e in parse() if declared_in(e, env) and e["lifecycle"] == "active"
    }
    cap_out = []
    gap_in_checked = False
    for cap in caps:
        parts, findings, missing, requires = [], set(), [], []
        bash_gap = False
        for requirement in cap["requires_list"]:
            namespace, name = _requirement_name(env, requirement)
            requires.append(name)
            row = rows.get(name)
            if namespace not in env_namespaces:
                finding, part = "dependency-outside-environment", "FAIL"
                bash_gap = True
            elif row is None:
                finding, part = "dependency-missing", "FAIL"
                bash_gap = namespace in facts["read"]
            elif row["lifecycle"] == "parked":
                finding, part = "dependency-parked", "FAIL"
                bash_gap = namespace in facts["read"]
            elif row["presence"] == "unknown":
                finding, part = "dependency-unread", "UNKNOWN"
            elif row["presence"] == "absent":
                finding = "dependency-planned" if row["lifecycle"] == "planned" else "dependency-missing"
                part = "FAIL"
                bash_gap = True
            elif row["verdict"] != "OK":
                finding, part = "dependency-invalid", row["verdict"]
            else:
                continue
            findings.add(finding)
            parts.append(part)
            if part == "FAIL":
                missing.append(name)
        verdict = _verdict(parts)
        drives = cap["state"] == "enabled" or include_planned
        if drives and bash_gap:
            gap_in_checked = True
        cap_out.append({
            "name": cap["name"],
            "kind": cap.get("kind", "feature"),
            "status": cap["state"],
            "verdict": verdict,
            "ready": verdict == "OK",
            "missing": missing,
            "findings": sorted(findings),
            "requires": requires,
            "drives_exit": drives,
        })

    errors = []
    skipped = sorted(facts["skipped"])
    for namespace in skipped:
        info = facts["skipped"][namespace]
        errors.append(f"{namespace}: cannot list {info['prefix']} — {info['detail']}")
    if facts["tags_skipped"]:
        errors.append(f"tags: {facts['tags_skipped']}")
    if facts["aborted"]:
        errors.append(f"aborted: {facts['aborted']}")
    partial = bool(skipped or facts["tags_skipped"] or facts["aborted"])

    profile = tools or declares(env)
    checks_caps = strict and not tools

    # validate.sh printed its classes; the classes this report implies must be
    # the same set. A difference is a defect in one of the two halves, and it
    # must never resolve to a softer verdict than the one that was printed.
    derived = {f for row in rows.values() for f in row["findings"]}
    if checks_caps and gap_in_checked:
        derived.add("capability-not-ready")
    if checks_caps and not profile:
        derived.add("no-capability-profile")
    if partial and not facts["aborted"]:
        derived.add("skipped")
    disagreement = None
    if not facts["aborted"] and derived != facts["classes"]:
        disagreement = (
            f"validator-disagreement: validate.sh printed {sorted(facts['classes'])}, "
            f"the report derives {sorted(derived)}"
        )

    parts = [row["verdict"] for row in rows.values()]
    if checks_caps:
        parts += [c["verdict"] for c in cap_out if c["drives_exit"]]
        if not profile:
            parts.append("FAIL")
    if partial:
        parts.append("UNKNOWN")
    overall = _verdict(parts)
    # A failed validate.sh with an UNKNOWN report is the strict SKIPPED case;
    # a passing one with UNKNOWN is the default-mode one. Anything else must
    # agree exactly.
    if validator_status is not None and not facts["aborted"]:
        if (validator_status != 0 and overall == "OK") or (validator_status == 0 and overall == "FAIL"):
            disagreement = disagreement or (
                f"validator-disagreement: validate.sh exited {validator_status}, the report verdict is {overall}"
            )
    if disagreement:
        errors.append(disagreement)
        overall = "FAIL"

    core_rows = [row for row in rows.values() if not row["capabilities"]]
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "env": env,
        "generated_at": _iso(now),
        "manifest_sha": manifest_sha(),
        "basis": "ci" if os.environ.get("GITHUB_ACTIONS") == "true" else "owner",
        "strict": bool(strict),
        "include_planned": bool(include_planned),
        "verdict": overall,
        "collection": {
            "status": "partial" if partial else "complete",
            "skipped_namespaces": skipped,
            "errors": errors,
        },
        "rows": [rows[name] for name in sorted(rows)],
        "capabilities": cap_out,
        "core": {"rows": len(core_rows), "verdict": _verdict([r["verdict"] for r in core_rows])},
    }


def aborted_report(env, reason, strict=False, include_planned=False):
    """What a run that stopped before its facts were complete still publishes."""
    now = _now()
    try:
        sha = manifest_sha()
    except OSError:
        sha = None
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "env": env,
        "generated_at": _iso(now),
        "manifest_sha": sha,
        "basis": "ci" if os.environ.get("GITHUB_ACTIONS") == "true" else "owner",
        "strict": bool(strict),
        "include_planned": bool(include_planned),
        "verdict": "UNKNOWN",
        "collection": {"status": "partial", "skipped_namespaces": [], "errors": [f"aborted: {reason}"]},
        "rows": [],
        "capabilities": [],
        "core": {"rows": 0, "verdict": "UNKNOWN"},
    }


EXIT_FOR_VERDICT = {"OK": 0, "FAIL": 1, "UNKNOWN": 2}


def write_json(path, document):
    import json

    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=False)
        handle.write("\n")
    os.replace(tmp, path)


def load_report(path, env):
    import json

    with open(path, encoding="utf-8") as handle:
        report = json.load(handle)
    if report.get("schema_version") != REPORT_SCHEMA_VERSION:
        raise ReportError(f"{path}: schema_version {report.get('schema_version')!r}, this reader knows {REPORT_SCHEMA_VERSION}")
    if report.get("env") != env:
        raise ReportError(f"{path}: report is for {report.get('env')!r}, not {env!r}")
    return report


def summary(report):
    """D-3: one line per capability, then the core group — markdown for the run
    summary. Displays the report's verdicts; decides nothing."""
    lines = [
        f"## Secrets readiness — {report['env']}",
        "",
        f"**{report['verdict']}** · {'strict' if report['strict'] else 'default mode'} · "
        f"collection {report['collection']['status']} · manifest `{(report['manifest_sha'] or '-')[:12]}` · "
        f"{report['generated_at']} · basis {report['basis']}",
        "",
        "| capability | status | verdict | not ready because |",
        "|---|---|---|---|",
    ]
    for cap in report["capabilities"]:
        because = ", ".join(cap["findings"]) or "—"
        lines.append(f"| {cap['name']} | {cap['status']} | {cap['verdict']} | {because} |")
    lines.append(f"| core ({report['core']['rows']} rows in no capability) | — | {report['core']['verdict']} | — |")
    failing = [row for row in report["rows"] if row["verdict"] != "OK"]
    if failing:
        lines += ["", "| row | lifecycle | presence | verdict | findings |", "|---|---|---|---|---|"]
        for row in failing:
            lines.append(
                f"| `{row['path']}` | {row['lifecycle']} | {row['presence']} | {row['verdict']} | "
                f"{', '.join(row['findings']) or '—'} |"
            )
    if report["collection"]["errors"]:
        lines += ["", "Collection:"] + [f"- {error}" for error in report["collection"]["errors"]]
    lines += [
        "",
        "Names, types, presence and dates only — no value was read. `parameter_age_days` is the SSM",
        "update age, not rotation provenance. Provider-side validity is not covered (`verified: not-checked`).",
    ]
    return "\n".join(lines) + "\n"


def project_deploy(report, release_sha, run_id, run_attempt):
    """D-6-B: the backend runtime slice of a report, for the deploy host. An
    allowlist, so a field added to the report never reaches the host by
    default (A-F-05)."""
    if not re.fullmatch(r"[0-9a-f]{40}", release_sha or ""):
        raise ReportError(f"release sha must be a full commit id (got {release_sha!r})")
    if not re.fullmatch(r"[0-9]+", run_id or ""):
        raise ReportError(f"run id must be a GitHub run id (got {run_id!r})")
    # "Re-run jobs" keeps the run id and renders SSM again: the attempt is what
    # makes a re-run a deploy of its own (GoGo-Infra#309 review).
    if not re.fullmatch(r"[0-9]+", run_attempt or ""):
        raise ReportError(f"run attempt must be a GitHub run attempt (got {run_attempt!r})")
    if any(e.startswith(("aborted:", "validator-disagreement:")) for e in report["collection"]["errors"]):
        raise ReportError("the report did not complete; a deploy does not carry it")
    rows = [
        r for r in report["rows"]
        if r.get("namespace") == "backend" and r.get("consumer") == "runtime"
    ]
    unread = [r["path"] for r in rows if r["presence"] == "unknown"]
    if unread:
        raise ReportError(f"backend was not read ({len(unread)} runtime rows unknown); nothing to project")
    names = {r["path"] for r in rows}
    caps = [c for c in report["capabilities"] if c.get("requires") and set(c["requires"]) <= names]
    kept = {c["name"] for c in caps}
    projected_rows = []
    for row in rows:
        item = {field: row[field] for field in PROJECTION_ROW_FIELDS}
        item["capabilities"] = [c for c in row["capabilities"] if c in kept]
        projected_rows.append(item)
    return {
        "schema_version": report["schema_version"],
        "env": report["env"],
        "generated_at": report["generated_at"],
        "manifest_sha": report["manifest_sha"],
        "deploy_id": f"{release_sha}-{run_id}-{run_attempt}",
        "release_sha": release_sha,
        "run_id": run_id,
        "run_attempt": run_attempt,
        "rows": projected_rows,
        "capabilities": [{field: c[field] for field in PROJECTION_CAPABILITY_FIELDS} for c in caps],
    }


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

    def value_of(flag):
        index = args.index(flag)
        if index + 1 >= len(args) or args[index + 1].startswith("--"):
            raise ReportError(f"{flag} needs a value")
        return args[index + 1]

    try:
        # Readiness report (GoGo-Infra#309). Called by validate.sh, the
        # readiness workflow and the deploy; see the section above main().
        if "--validator-classes" in args:
            for heading, code in VALIDATOR_CLASSES:
                sys.stdout.write(f"{heading}\t{code}\n")
            return 0

        if "--report-build" in args:
            status = value_of("--validator-status") if "--validator-status" in args else None
            report = build_report(
                env,
                read_facts(value_of("--facts")),
                strict="--strict" in args,
                include_planned=include_planned,
                validator_status=int(status) if status is not None else None,
            )
            write_json(value_of("--out"), report)
            return EXIT_FOR_VERDICT[report["verdict"]]

        if "--report-aborted" in args:
            write_json(
                value_of("--report-aborted"),
                aborted_report(env, value_of("--reason"), "--strict" in args, include_planned),
            )
            return EXIT_FOR_VERDICT["UNKNOWN"]

        if "--summary" in args:
            sys.stdout.write(summary(load_report(value_of("--summary"), env)))
            return 0

        if "--project-deploy" in args:
            import json

            projection = project_deploy(
                load_report(value_of("--project-deploy"), env),
                value_of("--release-sha"),
                value_of("--run-id"),
                value_of("--run-attempt"),
            )
            sys.stdout.write(json.dumps(projection, indent=2) + "\n")
            return 0

        if "--destination-lifecycle" in args:
            index = args.index("--destination-lifecycle")
            if index + 1 >= len(args):
                sys.stderr.write("--destination-lifecycle needs a full SSM name\n")
                return 2
            reason = destination_lifecycle(args[index + 1])
            if reason:
                sys.stdout.write(reason + "\n")
            return 0

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

        if "--check" in args:
            parse()
            parse("retired")
            return 0

        if "--declares" in args:
            # Exit status only: 0 when the environment has a profile, 1 when it does
            # not. Shell callers should not have to parse prose for this.
            return 0 if declares(env) else 1

        if "--all-namespaces" in args:
            # Discovery asks where a value might have been stored, not which
            # rows are declared here today. Even a namespace whose final row
            # is scoped to another environment must be listed, or validation
            # cannot find its undeclared values (Sol F-02, GoGo-Infra#308).
            namespaces = {
                row.get("namespace", "backend")
                for row in parse() + parse("retired")
                if (row.get("namespace", "backend") == "tools") == (env == "tools")
            }
            for namespace in sorted(namespaces):
                sys.stdout.write(namespace + "\n")
            return 0

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
    except ReportError as error:
        sys.stderr.write(f"error: {error}\n")
        return 2
    except (OSError, ValueError) as error:
        # An unreadable facts or report file, or one that is not JSON.
        sys.stderr.write(f"error: {error}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main())
