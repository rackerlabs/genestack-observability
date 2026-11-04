# F5 BIG-IP HA monitoring

This document is the source of truth for the reusable F5 BIG-IP HA monitoring
and alerting design. Runtime Collector configuration remains in each
environment repository. The reusable Prometheus rules live in this repository
and are deployed by the Genestack Prometheus rules chart.

## Architecture and ownership

Each environment has one F5 HA pair with two members. A centralized
OpenTelemetry Deployment Collector polls one scalar from each member through
SNMPv3 over outbound UDP/161. The samples pass through the existing metrics
processing and Prometheus Remote Write path. Prometheus evaluates the reusable
rules in
[`../alerts/prometheus-alerts/f5/f5-bigip-ha.yaml`](../alerts/prometheus-alerts/f5/f5-bigip-ha.yaml),
and Alertmanager delivers the resulting alerts.

```text
F5 BIG-IP pair -- SNMPv3/UDP 161 --> OTel Deployment Collector
             --> metrics processing --> Prometheus Remote Write
             --> Prometheus rules --> Alertmanager
```

The node-local Collector DaemonSet must not contain these receivers. Otherwise,
every node would poll both external devices and remote-write duplicate series.
The Deployment Collector must have one replica, providing one logical poller
for each F5. There is one named receiver, resource processor, and metrics
pipeline per member so that member identity cannot leak between streams.

The implementation uses the Collector chart's existing arbitrary receiver,
processor, pipeline, environment-variable, and Secret extension points. No
F5-specific Genestack change or separate SNMP exporter is required.

## Environment contract

An environment supplies only the values needed to instantiate the two-member
design:

| Setting | Member 1 | Member 2 |
|---------|----------|----------|
| Receiver ID | `snmp/f5-<f5-member-1>` | `snmp/f5-<f5-member-2>` |
| Endpoint | `udp://<f5-management-endpoint-1>:161` | `udp://<f5-management-endpoint-2>:161` |
| `device` | `<f5-member-1>` | `<f5-member-2>` |
| `environment` | `<environment>` | `<environment>` |
| `ha_pair` | `<ha-pair>` | `<ha-pair>` |

Receiver IDs and `device` values must be meaningful, stable names rather than
management addresses. The shared receiver selector is
`receiver=~"snmp/f5-.+"`. Each environment also supplies the name of its
credentials Secret.

Because Helm merges mappings but replaces lists, an environment override may
add receiver, processor, and pipeline mappings without copying the base
Collector configuration. Any overridden lists, including environment-variable
or pipeline processor/exporter lists, must retain the required base entries.

## Receiver and security contract

Each receiver uses the OpenTelemetry Collector Contrib SNMP receiver with this
shape; placeholders are resolved by the environment override:

```yaml
snmp/f5-<f5-member-1>:
  endpoint: udp://<f5-management-endpoint-1>:161
  collection_interval: 60s
  timeout: 5s
  version: v3
  security_level: auth_priv
  user: ${env:F5_SNMP_USERNAME}
  auth_type: SHA256
  auth_password: ${env:F5_SNMP_AUTH_PASSWORD}
  privacy_type: AES256
  privacy_password: ${env:F5_SNMP_PRIVACY_PASSWORD}
  metrics:
    f5.bigip.failover.state:
      description: >-
        F5 BIG-IP failover state (0 unknown, 1 offline, 2 forced offline,
        3 standby, 4 active).
      unit: "1"
      gauge:
        value_type: int
      scalar_oids:
        - oid: 1.3.6.1.4.1.3375.2.1.14.3.1.0
```

The receiver retrieves the scalar instance explicitly; the base OID without
the terminal `.0` is not sufficient. Sixty-second polling supports the
two-minute warning while avoiding an unnecessarily aggressive rate. A
five-second timeout leaves ample time before the next poll.

SNMPv3 must use `auth_priv`, SHA256 authentication, and AES256 privacy. The
Secret is credentials-only and contains these keys:

```text
username
auth-password
privacy-password
```

The Collector receives them through three Secret-backed environment variables
and uses OTel environment substitution. Do not commit credentials or put
endpoints, device names, or HA-pair identity in the Secret. Create it safely
from protected files, without placing values in shell history:

```shell
kubectl -n monitoring create secret generic <secret-name> \
  --from-file=username=/secure/path/username \
  --from-file=auth-password=/secure/path/auth-password \
  --from-file=privacy-password=/secure/path/privacy-password \
  --dry-run=client -o yaml | kubectl apply -f -
```

The username is environment-owned; historical usernames are not defaults.

## Collector distribution and maturity

The SNMP receiver is in the Contrib distribution. The environment configuration
must inherit the image repository and version resolved by its pinned
`opentelemetry-kube-stack` chart rather than independently pinning a Collector
tag. At the version validated for this implementation, chart `0.13.1` resolves
OpenTelemetry Collector Contrib `0.141.0`; its SNMP metrics support is Alpha.

Keep the initial scope to this one scalar, the explicit interval and timeout,
one logical poller, and the pinned chart. Before any chart or Collector upgrade,
render the configuration, confirm the image still contains `snmp`, validate
the receiver enums and schema, and rerun the Prometheus rule tests. Rollback is
the ordinary environment-values rollback: remove the two receiver pipelines
and their three Secret environment references, then restore the last validated
release. The reusable rules may remain loaded because they select only named
F5 receivers and F5 state series.

## Metric and label contract

| Layer | Metric | Identity |
|-------|--------|----------|
| OpenTelemetry | `f5.bigip.failover.state` | Resource attributes `environment`, `ha_pair`, `device` |
| Prometheus | `f5_bigip_failover_state` | Labels `environment`, `ha_pair`, `device` |

The current Prometheus Remote Write exporter has
`resource_to_telemetry_conversion.enabled: true`, so those resource attributes
become labels. Prometheus normalizes the dotted OTel metric name to the
underscore-separated Prometheus name.

| Value | Meaning |
|-------|---------|
| `0` | unknown |
| `1` | offline |
| `2` | forced offline |
| `3` | standby |
| `4` | active |

## Per-receiver poll health

Prometheus does not scrape the F5, so it has no exporter-style `up` metric for
an SNMP attempt. Prometheus directly scrapes Collector self-telemetry through
the Deployment Collector ServiceMonitor instead. The selected signal is:

```promql
otelcol_scraper_scraped_metric_points_total{
  receiver=~"snmp/f5-.+",
  scraper="snmp"
}
```

The `receiver` label retains the full named component ID. A successful poll of
the configured scalar adds one point; a failed poll adds none. The rules use
`increase()` over the alert window and an offset guard requiring the counter to
have existed for the full window. This tolerates Collector counter resets and
avoids an immediate alert when a receiver first appears. It also distinguishes
an F5 that answered with state 0, 1, or 2 from a poll that produced no point.

This signal has deliberate limits:

- If the entire Deployment Collector or its ServiceMonitor disappears, the
  receiver-labelled counters disappear too; a separate platform-owned
  Collector-availability alert must cover that condition.
- Removing a receiver from configuration also removes the series. An
  inventory-derived expected-target metric would be required to name a target
  that never existed in self-telemetry.
- A Prometheus Remote Write failure can make the state metric stale while the
  directly scraped poll counter continues increasing. Remote Write health is a
  separate platform concern.

The F5 rule set intentionally does not add generic Collector-down or Remote
Write alerts. The next clean improvement for perfect first-deployment coverage
would be an expected-target metric generated from deployment inventory.

## Alert policy

| Condition | Warning | Critical | Evidence |
|-----------|---------|----------|----------|
| Per-target SNMP telemetry unavailable | 2 minutes | 5 minutes | Named receiver counter does not increase |
| Member reports state 0, 1, or 2 | 2 minutes | 5 minutes | `f5_bigip_failover_state` |
| Pair has no active member | 2 minutes | 5 minutes | No observed member equals `4` |
| Pair has no standby member | 5 minutes | 15 minutes | No observed member equals `3` |

Pair rules group by `environment` and `ha_pair`; no endpoint appears in their
PromQL. Pair-level loss of redundancy is intentionally not suppressed by a
member-level state alert. In particular, standby is value 3, not value 4.

## Rule ownership, deployment, and tests

[`../alerts/prometheus-alerts/f5/f5-bigip-ha.yaml`](../alerts/prometheus-alerts/f5/f5-bigip-ha.yaml)
is the reusable rule source. It retains the repository's
`additionalPrometheusRulesMap` source format. The `alerts` Helm chart discovers
the file and renders it as its own native `PrometheusRule`, which
`install-prometheus-rules.sh` deploys independently of
`kube-prometheus-stack`. Environment repositories must not carry or maintain a
generated copy of this rule set.

The reusable fixture is
[`../tests/f5-bigip-ha.test.yaml`](../tests/f5-bigip-ha.test.yaml). `promtool` is
Prometheus's command-line validator: `check rules` parses and type-checks the
PromQL rule file, while `test rules` evaluates the rules against synthetic time
series and compares the resulting alerts with the fixture's expectations.

Use the Prometheus version deployed by the environment, Helm, and `yq` v4. From
this repository's root, render the same chart used by deployment and extract
the F5 resource for promtool:

```shell
promtool --version
test_dir="$(mktemp -d)"
rules_file="${test_dir}/f5-bigip-ha.rules.yaml"
tests_file="${test_dir}/f5-bigip-ha.test.yaml"
helm template prometheus-rules alerts --namespace monitoring | \
  yq 'select(
    .kind == "PrometheusRule" and
    .metadata.annotations."genestack.io/rule-source" ==
      "prometheus-alerts/f5/f5-bigip-ha.yaml"
  ) | .spec' > "${rules_file}"
RULES_FILE="${rules_file}" yq '.rule_files = [strenv(RULES_FILE)]' \
  tests/f5-bigip-ha.test.yaml > "${tests_file}"
promtool check rules "${rules_file}"
promtool test rules "${tests_file}"
```

The fixture covers active/standby, two active members, two standby members,
unhealthy states 0/1/2, one stalled receiver, all state metrics absent, and an
explicit assertion that standby is value 3. These commands require no custom
Python test runner.

## Static validation for an environment

Render with the same base and environment values used by the current
observability deployment. `genestack-observability` owns the base values, while
the environment repository supplies global and service-specific overrides.
The service override now lives below `helm-configs/observability/`. This
pattern avoids printing secrets:

```shell
helm template opentelemetry-kube-stack \
  open-telemetry/opentelemetry-kube-stack \
  --version <chart-version> \
  --namespace monitoring \
  --values <genestack-observability>/helm-configs/opentelemetry-kube-stack/opentelemetry-kube-stack-helm-overrides.yaml \
  --values <environment-overrides>/helm-configs/global_overrides/endpoints.yaml \
  --values <environment-overrides>/helm-configs/global_overrides/logger.yaml \
  --values <environment-overrides>/helm-configs/observability/opentelemetry-kube-stack/opentelemetry-kube-stack-helm-overrides.yaml \
  > /tmp/opentelemetry-rendered.yaml

yq 'select(.kind == "OpenTelemetryCollector") |
  {"name": .metadata.name, "mode": .spec.mode, "replicas": .spec.replicas,
   "receivers": (.spec.config.receivers | keys),
   "pipelines": (.spec.config.service.pipelines | keys)}' \
  /tmp/opentelemetry-rendered.yaml
```

Confirm exactly one Deployment replica, exactly two `snmp/f5-*` receivers and
member pipelines, no SNMP receiver in the DaemonSet, three Secret key
references, and the `environment`, `ha_pair`, and `device` resource attributes.

## Live validation and troubleshooting

These commands require a deployed non-production environment. Replace the
placeholders with the release and member names obtained from the environment
override. They inspect references and metadata, never Secret values.

```shell
# Inspect the live Collector CRs and confirm one Deployment replica.
kubectl -n monitoring get opentelemetrycollector -o yaml
kubectl -n monitoring get deployment -l app.kubernetes.io/name=opentelemetry-collector

# Inspect receiver IDs, pipelines, image, and Secret key references.
kubectl -n monitoring get opentelemetrycollector <deployment-collector> \
  -o jsonpath='{.spec.image}{"\n"}{.spec.config.receivers}{"\n"}{.spec.env}{"\n"}'

# Confirm the running binary advertises the SNMP component. The Collector image
# may not contain a shell; use the binary directly, adjusting its path if needed.
kubectl -n monitoring exec deploy/<deployment-collector> -- \
  /otelcol-contrib components | grep -w snmp

# Review startup, authentication, timeout, and receiver errors.
kubectl -n monitoring logs deploy/<deployment-collector> --since=30m | \
  grep -Ei 'snmp|f5|error|timeout|authentication'

# Test UDP/161 from the same namespace/network context with a disposable tools
# pod; the Collector image itself is intentionally minimal.
kubectl -n monitoring run snmp-network-check --rm -it --restart=Never \
  --image=nicolaka/netshoot -- \
  nc -zvu -w5 <f5-management-endpoint-1> 161
```

The F5 must allowlist the Deployment pod's actual egress source and the network
must permit outbound UDP/161. A UDP connectivity probe is only preliminary; it
does not prove SNMP credentials or access-control views are correct.

Query Prometheus through its normal UI or API:

```promql
f5_bigip_failover_state{environment="<environment>"}

otelcol_scraper_scraped_metric_points_total{
  receiver=~"snmp/f5-.+",
  scraper="snmp"
}

ALERTS{alertname=~"f5-bigip-.+",alertstate=~"pending|firing"}
```

The first query must display both `device` values and their shared `ha_pair`;
normal HA operation is one value 4 and one value 3. In Prometheus **Status →
Rules**, verify the `f5-bigip-ha` group is loaded. The counter query should
increase once per successful 60-second poll for each named receiver.

For a safe fault test, change one non-production receiver endpoint in the
source-controlled environment override to an unroutable TEST-NET address such
as `udp://192.0.2.1:161`, render and deploy through the normal process, and
observe the warning after two minutes and critical after five. Restore the
reviewed endpoint through the same process and confirm the counter resumes and
alerts clear. An equivalent bad-credential test should use a temporary Secret
created through the approved secret workflow; never print or commit either the
original or test credentials.
