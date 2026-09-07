#!/usr/bin/env bash
# Static validation for the administrative-data alerting provisioning. INF-156.
#
# The first alert rules this repository has ever carried, so this file also sets
# the convention. It runs with no network, no Grafana and no Prometheus: every
# assertion is about the files, because the thing it is guarding against is a
# rule that loads cleanly and means nothing.
#
# YAML is parsed with Ruby's Psych rather than PyYAML. `scripts/lib/manifest.py`
# already explains why this repository does not assume a YAML library is
# installed; ruby ships on macOS and on ubuntu-latest, PyYAML does not ship on
# the first.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$here" || exit 2

alerting="observability/local-grafana/grafana/provisioning/alerting"
compose="observability/local-grafana/docker-compose.yml"
prom="observability/local-grafana/prometheus/prometheus.yml"

fail=0
note() { printf '  %s\n' "$1"; }
check() {
  local name="$1"; shift
  if "$@"; then
    printf 'ok    %s\n' "$name"
  else
    printf 'FAIL  %s\n' "$name"
    fail=1
  fi
}

command -v ruby >/dev/null || { echo "ruby is required to parse YAML" >&2; exit 2; }

json_of() { ruby -ryaml -rjson -e 'puts YAML.load_file(ARGV[0]).to_json' "$1"; }

# ---------------------------------------------------------------------------
# 1. Every provisioning file is syntactically valid YAML and declares apiVersion.
# ---------------------------------------------------------------------------
for f in "$alerting"/*.yaml; do
  check "parses as YAML: ${f##*/}" bash -c "ruby -ryaml -e 'YAML.load_file(ARGV[0])' '$f' >/dev/null 2>&1"
  check "declares apiVersion 1: ${f##*/}" \
    bash -c "ruby -ryaml -e 'exit(YAML.load_file(ARGV[0])[\"apiVersion\"] == 1 ? 0 : 1)' '$f'"
done

# ---------------------------------------------------------------------------
# 2. The rule file, in depth.
# ---------------------------------------------------------------------------
rules_json="$(json_of "$alerting/administrative-rules.yaml")"
policies_json="$(json_of "$alerting/notification-policies.yaml")"
contacts_json="$(json_of "$alerting/contact-points.yaml")"
templates_json="$(json_of "$alerting/templates.yaml")"

RULES_JSON="$rules_json" POLICIES_JSON="$policies_json" \
CONTACTS_JSON="$contacts_json" TEMPLATES_JSON="$templates_json" \
python3 - <<'PY'
import json, os, re, sys

rules = json.loads(os.environ["RULES_JSON"])
policies = json.loads(os.environ["POLICIES_JSON"])
contacts = json.loads(os.environ["CONTACTS_JSON"])
templates = json.loads(os.environ["TEMPLATES_JSON"])

problems = []
def want(cond, msg):
    if not cond:
        problems.append(msg)

DATASOURCE_UID = "gogo-prometheus-local"
FOLDER = "GoGo Administrative Data"
CONTACT = "gogo-administrative-telegram"
PAUSE = "${GOGO_ADM_ALERTS_PAUSED}"

groups = rules["groups"]
want(len(groups) == 1, f"expected exactly one rule group, found {len(groups)}")
g = groups[0]
want(g["folder"] == FOLDER, f"folder is {g['folder']!r}, expected {FOLDER!r}")
want(g["interval"] == "60s",
     f"group interval is {g['interval']!r}; Alloy scrapes every 60s and evaluation must not be faster")

rs = g["rules"]
uids = [r["uid"] for r in rs]
titles = [r["title"] for r in rs]
want(len(set(uids)) == len(uids), f"duplicate rule uid: {[u for u in uids if uids.count(u) > 1]}")
# Grafana's own constraint, from rules_types.go: "Should not exceed 40 symbols.
# Only letters, numbers, - (hyphen), and _ (underscore) allowed." A uid that
# breaks it fails provisioning at start, which is a slow way to find out.
for u in uids:
    want(len(u) <= 40, f"rule uid {u!r} is {len(u)} characters; Grafana's limit is 40")
    want(re.fullmatch(r"[A-Za-z0-9_-]+", u), f"rule uid {u!r} uses characters Grafana rejects")
want(len(set(titles)) == len(titles), f"duplicate rule title: {[t for t in titles if titles.count(t) > 1]}")

# The metric contract, mirrored from GoGo-BE cf5989c / dd3d1ee
# (libs/observability/src/metric-labels.ts).
#
# A mirror and not a cross-check, deliberately. Reading the sibling GoGo-BE
# checkout would look stronger and be worse: CI clones one repository, so the
# check would silently skip there, and on a developer machine it would compare
# against whatever commit that checkout happens to sit at. A stale checkout then
# fails this build for a contract that is perfectly fine — which is a false
# alarm about false alarms.
#
# The authority is GoGo-BE's own metric-labels.spec.ts, which fails ITS build if
# an emission drifts from the contract. This list only stops a rule here from
# naming a metric that never existed. Update it when BE adds one.
KNOWN = {
    "administrative_dataset_active", "administrative_dataset_age_seconds",
    "administrative_datasets", "administrative_quarantined_changes",
    "administrative_unresolved_changes", "administrative_boundary_active",
    "administrative_boundary_age_seconds", "administrative_boundary_units",
    "administrative_mappings", "administrative_remediation",
    "administrative_publication_enabled",
    "administrative_dataset_operations_total",
    "administrative_dataset_operation_duration_seconds",
    "administrative_validation_findings_total",
    "administrative_cache_refresh_total",
    "administrative_boundary_loads_total",
    "administrative_boundary_findings_total",
    "administrative_backfill_runs_total", "administrative_backfill_places_total",
    "administrative_backfill_version_stops_total",
    "administrative_override_materializations_total",
    "administrative_override_conflicts_total",
    "administrative_override_decisions_total",
    "administrative_override_queue_reads_total",
    "administrative_moderation_actions_total",
    "administrative_mapping_writes_total",
    "administrative_stale_evaluations_total",
    "administrative_resolver_runs_total",
}
REQUIRED_ANNOTATIONS = ("summary", "impact", "expected", "description", "runbook")
NODATA = {"Alerting", "OK", "NoData"}
EXECERR = {"Alerting", "OK", "Error"}
metric_re = re.compile(r"\b(administrative_[a-z0-9_]+|place_[a-z0-9_]+)\b")

for r in rs:
    uid = r["uid"]
    want(r.get("condition") == "B", f"{uid}: condition must be B")
    want(r.get("isPaused") == PAUSE,
         f"{uid}: isPaused must be {PAUSE} so activation is a recorded step, found {r.get('isPaused')!r}")
    want("for" in r, f"{uid}: no `for` duration")
    want(r.get("noDataState") in NODATA, f"{uid}: noDataState {r.get('noDataState')!r} not one of {NODATA}")
    want(r.get("execErrState") in EXECERR, f"{uid}: execErrState {r.get('execErrState')!r} not one of {EXECERR}")

    labels = r.get("labels", {})
    want(labels.get("service") == "administrative-data",
         f"{uid}: label service must be administrative-data, else the notification policy will not route it")
    want(labels.get("env") == "dev", f"{uid}: label env must be dev; this ADR is DEV-only")
    want(labels.get("severity") in {"high", "warning"}, f"{uid}: severity {labels.get('severity')!r}")

    ann = r.get("annotations", {})
    for key in REQUIRED_ANNOTATIONS:
        want(key in ann and ann[key].strip(), f"{uid}: missing annotation {key!r}")
    want(str(ann.get("runbook", "")).startswith("docs/runbook-administrative-alerts.md#"),
         f"{uid}: runbook annotation must point into docs/runbook-administrative-alerts.md")
    want(ann.get("runbook") == f"docs/runbook-administrative-alerts.md#{uid}",
         f"{uid}: runbook anchor must match the rule uid")

    data = r["data"]
    want(len(data) == 2, f"{uid}: expected one query and one threshold, found {len(data)}")
    q, thr = data[0], data[1]
    want(q["datasourceUid"] == DATASOURCE_UID,
         f"{uid}: query datasourceUid is {q['datasourceUid']!r}, expected {DATASOURCE_UID!r}")
    want(q["model"]["datasource"]["uid"] == DATASOURCE_UID, f"{uid}: model datasource uid mismatch")
    want(thr["datasourceUid"] == "__expr__", f"{uid}: threshold must be a server-side expression")
    want(thr["model"]["expression"] == "A", f"{uid}: threshold must read refId A")

    expr = q["model"]["expr"]
    want(q["model"].get("instant") is True, f"{uid}: query must be instant")
    want('env="dev"' in expr, f"{uid}: query does not pin env=\"dev\"")
    want("staging" not in expr and "prod" not in expr, f"{uid}: query names a non-DEV environment")

    for metric in metric_re.findall(expr):
        want(metric in KNOWN,
             f"{uid}: query references {metric!r}, which is not in the merged BE metric contract")

    # Counters are read over a window, never as a lifetime total.
    counters = [m for m in metric_re.findall(expr) if m.endswith("_total")]
    if counters:
        want("increase(" in expr or "rate(" in expr,
             f"{uid}: reads a _total counter without increase()/rate(); a lifetime total fires on history")

    # The relative time range must cover the range selector the query uses.
    windows = {"m": 60, "h": 3600, "d": 86400}
    for num, unit in re.findall(r"\[(\d+)([mhd])\]", expr):
        need = int(num) * windows[unit]
        want(q["relativeTimeRange"]["from"] >= need,
             f"{uid}: relativeTimeRange.from={q['relativeTimeRange']['from']}s is shorter than its [{num}{unit}] selector")

# The five accepted baselines must never be alerted on by level.
BASELINE_METRICS = {
    "administrative_quarantined_changes",
    "administrative_unresolved_changes",
    "administrative_remediation",
    "administrative_mappings",
}
for r in rs:
    expr = r["data"][0]["model"]["expr"]
    hit = BASELINE_METRICS & set(metric_re.findall(expr))
    if hit:
        want("delta(" in expr or "min_over_time(" in expr or "increase(" in expr,
             f"{r['uid']}: reads {sorted(hit)} at its LEVEL. The pinned dataset carries "
             "1,033 unresolved / 1,370 simplification / 233 overlap / 56 outlier / 1 formatting "
             "warnings by design; alert on delta, never on level.")

# The two populations that must not be summed together.
for r in rs:
    expr = r["data"][0]["model"]["expr"]
    want(not ("administrative_remediation" in expr and "administrative_quarantined_changes" in expr),
         f"{r['uid']}: sums administrative_remediation with administrative_quarantined_changes. "
         "Remediation counts published places against the active version; quarantine counts rows "
         "of a dataset. Different populations.")

# --- contact point ---------------------------------------------------------
cps = contacts["contactPoints"]
want(len(cps) == 1, f"expected one contact point, found {len(cps)}")
cp = cps[0]
want(cp["name"] == CONTACT, f"contact point name is {cp['name']!r}")
recv = cp["receivers"]
want(len(recv) == 1 and recv[0]["type"] == "telegram", "expected exactly one telegram receiver")
rc = recv[0]
want(rc.get("disableResolveMessage") is False,
     "disableResolveMessage must be false: resolved notifications are part of the acceptance run")
settings = rc["settings"]
want(settings.get("bottoken") == "${GRAFANA_TELEGRAM_BOT_TOKEN}",
     "bot token must be an environment reference, never a literal")
want(settings.get("chatid") == "${GRAFANA_TELEGRAM_CHAT_ID}",
     "chat id must be an environment reference, never a literal")

# --- notification policy ---------------------------------------------------
pols = policies["policies"]
want(len(pols) == 1, f"expected one root policy, found {len(pols)}")
root = pols[0]
want(root["receiver"] == "${GOGO_ALERTS_DEFAULT_RECEIVER}",
     "root receiver must stay the org default; provisioning policies replaces the whole tree")
routes = root.get("routes", [])
want(len(routes) == 1, f"expected exactly one child route, found {len(routes)}")
route = routes[0]
want(route["receiver"] == CONTACT, f"child route receiver is {route['receiver']!r}")
want(route["object_matchers"] == [["service", "=", "administrative-data"]],
     f"child route must match only service=administrative-data, found {route['object_matchers']}")
want("continue" not in route,
     "child route must not set continue: an administrative alert would then also hit the root receiver")

# --- template --------------------------------------------------------------
tpls = templates["templates"]
want(len(tpls) == 1, f"expected one template, found {len(tpls)}")
body = tpls[0]["template"]
want(tpls[0]["name"] == "gogo.administrative.telegram", "template name mismatch")
for token in (".Labels.severity", ".Labels.alertname", ".Labels.env",
              ".ValueString", ".Annotations.runbook", ".GeneratorURL"):
    want(token in body, f"template omits {token}")
FORBIDDEN = ("bottoken", "chatid", "datasetId", "combinedDatasetVersion",
             "checksum", "placeId", "reviewer")
for token in FORBIDDEN:
    want(token not in body, f"template references {token!r}; identities do not go to Telegram")

if problems:
    print("FAIL  provisioning content")
    for p in problems:
        print("      - " + p)
    sys.exit(1)
print(f"ok    provisioning content ({len(rs)} rules, 1 contact point, 1 route, 1 template)")
PY
[[ $? -ne 0 ]] && fail=1

# ---------------------------------------------------------------------------
# 3. No credential anywhere in the provisioning files, and no second evaluator.
# ---------------------------------------------------------------------------
check "no literal telegram bot token shape in provisioning" \
  bash -c "! grep -rEq '[0-9]{8,10}:[A-Za-z0-9_-]{30,}' '$alerting'"
check "no SSM parameter VALUES, only names, in tracked files" \
  bash -c "! grep -rEq 'GRAFANA_TELEGRAM_(BOT_TOKEN|CHAT_ID)=[^\$[:space:]]' '$alerting' observability/local-grafana/.env.example '$compose'"
check "prometheus.yml still loads no rule_files (one evaluator, ADR-0009 §F2)" \
  bash -c "! grep -Eq '^[[:space:]]*rule_files:' '$prom'"
check "prometheus.yml still configures no alertmanager" \
  bash -c "! grep -Eq '^[[:space:]]*alerting:' '$prom'"
check "no alertmanager service in the observability stack" \
  bash -c "! grep -Eq '^[[:space:]]+alertmanager:' '$compose'"
check "no rules directory mounted into prometheus" \
  bash -c "! grep -q '/etc/prometheus/rules' '$compose'"

# ---------------------------------------------------------------------------
# 4. Compose wiring fails loudly rather than silently.
# ---------------------------------------------------------------------------
check "GOGO_ADM_ALERTS_PAUSED is required by compose (:?)" \
  bash -c "grep -q 'GOGO_ADM_ALERTS_PAUSED:.*:?' '$compose'"
check ".env.alerting is loaded with required: true" \
  bash -c "grep -A1 'path: ./.env.alerting' '$compose' | grep -q 'required: true'"
check ".env.alerting is gitignored" \
  bash -c "grep -qx '.env.alerting' observability/local-grafana/.gitignore"
check ".env.alerting is not tracked" \
  bash -c "! git ls-files --error-unmatch observability/local-grafana/.env.alerting >/dev/null 2>&1"
check "GOGO_ADM_ALERTS_PAUSED defaults to true in .env.example" \
  bash -c "grep -qx 'GOGO_ADM_ALERTS_PAUSED=true' observability/local-grafana/.env.example"
check "OBS_BIND_IP still has no default in compose (ADR-0007 §E4)" \
  bash -c "grep -q 'OBS_BIND_IP:?' '$compose'"

# ---------------------------------------------------------------------------
# 5. The render script and the manifest describe the same two parameters.
# ---------------------------------------------------------------------------
render="observability/local-grafana/bin/render-alerting-env.sh"
for pair in "grafana-telegram-bot-token:GRAFANA_TELEGRAM_BOT_TOKEN" \
            "grafana-telegram-chat-id:GRAFANA_TELEGRAM_CHAT_ID"; do
  path="${pair%%:*}"; var="${pair#*:}"
  check "manifest declares observability/${path}" \
    bash -c "python3 scripts/lib/manifest.py dev --consumer all | grep -q '^observability/${path}	${var}	SecureString'"
  check "render script reads observability/${path}" \
    bash -c "grep -q '${path}:${var}' '$render'"
done
check "telegram parameters are NOT rendered into the API env file" \
  bash -c "! python3 scripts/lib/manifest.py dev | grep -qi telegram"
check "telegram parameters carry consumer: observability" \
  bash -c "python3 scripts/lib/manifest.py dev --consumer observability | grep -c telegram | grep -qx 2"

# ---------------------------------------------------------------------------
# 6. Every rule uid has a runbook section, and the runbook has no orphans.
# ---------------------------------------------------------------------------
runbook="docs/runbook-administrative-alerts.md"
check "runbook exists" test -f "$runbook"
if [[ -f "$runbook" ]]; then
  missing=""
  for uid in $(echo "$rules_json" | python3 -c 'import json,sys; [print(r["uid"]) for r in json.load(sys.stdin)["groups"][0]["rules"]]'); do
    grep -q "^### ${uid}\$" "$runbook" || missing="${missing} ${uid}"
  done
  check "every rule uid has a runbook section" bash -c "[ -z '${missing}' ] || { echo 'missing:${missing}' >&2; false; }"
  orphans=""
  while read -r heading; do
    echo "$rules_json" | grep -q "\"${heading}\"" || orphans="${orphans} ${heading}"
  done < <(sed -n 's/^### \(adm-[a-z-]*\)$/\1/p' "$runbook")
  check "runbook has no section for a rule that does not exist" \
    bash -c "[ -z '${orphans}' ] || { echo 'orphans:${orphans}' >&2; false; }"
fi

exit "$fail"
