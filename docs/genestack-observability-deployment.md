# Deploy Genestack Observability on an Overseer

## Overview

`genestack-observability` contains the monitoring-specific Helm configuration,
Kustomize configuration, alerting and recording rules, and service installation
implementations used by Genestack observability deployments.

The repository is installed on a Genestack overseer at:

```text
/opt/genestack-observability
```

The primary Genestack checkout remains at:

```text
/opt/genestack
```

The design intentionally separates **operator-facing orchestration** from
**observability service implementation**:

```text
Genestack
  /opt/genestack/bin/
    bootstrap-observability.sh
    install-observability.sh
    loki-sync-rules.sh
        |
        | orchestrates
        v
genestack-observability
  /opt/genestack-observability/bin/
    bootstrap-observability.sh
    install-observability.sh
    create-secrets.sh
    install-kube-prometheus-stack.sh
    install-prometheus-pushgateway.sh
    install-barbican-exporter.sh
    install-openstack-exporter.sh
    install-opentelemetry-kube-stack.sh
    install-tempo.sh
    install-loki.sh
    install-grafana.sh
    install-prometheus-rules.sh
    install-lokitool.sh
    loki-sync-rules.sh
    setup-monitoring-rgw-storage.sh
```

`bootstrap-observability.sh`, `install-observability.sh`, and
`loki-sync-rules.sh` may be shipped from Genestack as stable operator-facing
entrypoints while the actual service implementations remain owned by
`genestack-observability`.

## Prerequisites

The overseer is expected to already have a working Genestack environment,
including:

```text
/opt/genestack
/opt/genestack/base-helm-configs
/opt/genestack/base-kustomize
/etc/genestack
```

The normal Genestack administrative tooling such as `kubectl`, `helm`, `yq`,
`jq`, `curl`, Git, and `sudo` should already be available.

The account performing the bootstrap must be able to clone:

```text
git@github.com:rackerlabs/genestack-observability.git
```

The bootstrap normally runs as the standard overseer operator account, for
example `ubuntu`. Elevated privileges are used only when needed to create or
repair ownership of `/opt/genestack-observability`; Git operations run as the
repository owner rather than root.

## Repository layout

The relevant observability layout is:

```text
/opt/genestack-observability/
├── alerts/
│   ├── prometheus-alerts/
│   ├── recording/
│   └── loki-alerts/
├── bin/
│   ├── bootstrap-observability.sh
│   ├── install-observability.sh
│   ├── create-secrets.sh
│   ├── install-barbican-exporter.sh
│   ├── install-grafana.sh
│   ├── install-kube-prometheus-stack.sh
│   ├── install-loki.sh
│   ├── install-lokitool.sh
│   ├── install-openstack-exporter.sh
│   ├── install-opentelemetry-kube-stack.sh
│   ├── install-prometheus-pushgateway.sh
│   ├── install-prometheus-rules.sh
│   ├── install-tempo.sh
│   ├── loki-sync-rules.sh
│   ├── monitoring-common.sh
│   ├── observability-components.yaml
│   ├── setup-monitoring-rgw-storage.sh
│   └── yamlparse.py
├── etc/
│   └── gateway-api/
│       ├── listeners/
│       └── routes/
├── helm-configs/
├── kustomize/
└── versions/
    └── lokitool
```

The following are orchestration or support files, not observability services:

```text
bootstrap-observability.sh
install-observability.sh
create-secrets.sh
install-lokitool.sh
loki-sync-rules.sh
monitoring-common.sh
yamlparse.py
observability-components.yaml
```

`setup-monitoring-rgw-storage.sh` is modeled as an installable prerequisite
operation named `monitoring-rgw-storage`.

All scripts should use:

```bash
GENESTACK_OBSERVABILITY_DIR="${GENESTACK_OBSERVABILITY_DIR:-/opt/genestack-observability}"
```

and must not depend on the caller changing directories first.

## Genestack integration

The observability Helm configuration is linked into:

```text
/opt/genestack/base-helm-configs/observability
```

The observability Kustomize configuration is linked into:

```text
/opt/genestack/base-kustomize/observability
```

The resulting paths are:

```text
/opt/genestack/base-helm-configs/observability
  -> /opt/genestack-observability/helm-configs

/opt/genestack/base-kustomize/observability
  -> /opt/genestack-observability/kustomize
```

The bootstrap script refuses to replace an existing non-symlink path at either
target.

The bootstrap also prepares missing site configuration beneath:

```text
/etc/genestack/helm-configs/observability
/etc/genestack/kustomize/observability
```

Existing site service directories are never overwritten or merged. For a fresh
lab, missing Helm service directories are seeded from the repository and
minimal Kustomize overlays are created as needed.

## Repository ownership and `/opt`

`/opt` is normally root-owned, so a non-root operator cannot create
`/opt/genestack-observability` directly.

Bootstrap handles this boundary explicitly:

1. determine the repository owner;
2. use root or `sudo` only to create/chown the repository directory;
3. run `git clone`, `git pull`, and submodule operations as the repository
   owner;
4. repair an accidentally root-owned existing checkout when necessary.

The repository owner defaults to `SUDO_USER` when bootstrap is launched through
`sudo`; otherwise it defaults to the invoking user. The owner and group can be
overridden explicitly:

```bash
GENESTACK_OBSERVABILITY_OWNER=ubuntu \
GENESTACK_OBSERVABILITY_GROUP=ubuntu \
  /opt/genestack/bin/bootstrap-observability.sh
```

Bootstrap permits an existing empty `/opt/genestack-observability` directory as
a clone target, but refuses to delete or overwrite a non-empty directory that
is not a Git checkout.

## Secret ownership

Secrets remain split along the same repository boundary as the deployment
code.

Core Genestack owns OpenStack and infrastructure credentials in:

```text
/etc/genestack/kubesecrets.yaml
```

Generate core secrets first on a new environment:

```bash
/opt/genestack/bin/create-secrets.sh
```

The Keystone admin credential produced by core Genestack is reused by the
OpenStack exporter.

`genestack-observability` also provides:

```text
/opt/genestack-observability/bin/create-secrets.sh
```

which can create or extend:

```text
/etc/genestack/observability-secrets.yaml
```

for observability-owned manifests such as the monitoring namespace,
`mariadb-monitoring`, and `keystone-auth-openstack-exporter`.

Secret generation is a separate operation. The current
`bootstrap-observability.sh` does **not** automatically run
`create-secrets.sh`, and it does not provide `--create-secrets` or
`--skip-create-secrets` bootstrap flags.

Individual service installers may also use `monitoring-common.sh` to ensure
runtime monitoring Secrets exist in the namespaces where they are consumed.

## Component enablement

Observability component selection follows the same style as Genestack's
component configuration: each component is enabled or disabled with a boolean.

The repository default is:

```text
/opt/genestack-observability/bin/observability-components.yaml
```

An optional site override may be created at:

```text
/etc/genestack/observability-components.yaml
```

Bootstrap does **not** copy or seed the repository component file into
`/etc/genestack`. This is intentional: the repository default remains the
normal source unless an operator deliberately creates a site override.

The unified installer resolves component configuration in this order:

1. `OBSERVABILITY_COMPONENTS_FILE`, when explicitly set;
2. `/etc/genestack/observability-components.yaml`, when it exists;
3. `/opt/genestack-observability/bin/observability-components.yaml`.

The repository default component set is:

```yaml
---
components:
  monitoring-rgw-storage: false
  kube-prometheus-stack: true
  prometheus-pushgateway: true
  barbican-exporter: true
  openstack-exporter: true
  tempo: false
  loki: true
  opentelemetry-kube-stack: true
  grafana: true
  prometheus-rules: true
  loki-rules: true

install_order:
  - monitoring-rgw-storage
  - kube-prometheus-stack
  - prometheus-pushgateway
  - barbican-exporter
  - openstack-exporter
  - tempo
  - loki
  - opentelemetry-kube-stack
  - grafana
  - prometheus-rules
  - loki-rules
```

The explicit install order avoids depending on YAML map ordering and gives
initial deployments a deterministic dependency sequence.

For example, a site override for a cluster that should run Prometheus without
Loki can contain:

```yaml
---
components:
  monitoring-rgw-storage: false
  kube-prometheus-stack: true
  prometheus-pushgateway: true
  barbican-exporter: true
  openstack-exporter: true
  tempo: false
  loki: false
  opentelemetry-kube-stack: true
  grafana: true
  prometheus-rules: true
  loki-rules: false

install_order:
  - monitoring-rgw-storage
  - kube-prometheus-stack
  - prometheus-pushgateway
  - barbican-exporter
  - openstack-exporter
  - tempo
  - loki
  - opentelemetry-kube-stack
  - grafana
  - prometheus-rules
  - loki-rules
```

A one-off component configuration can also be supplied without creating a site
file:

```bash
OBSERVABILITY_COMPONENTS_FILE=/tmp/observability-components.yaml \
  /opt/genestack/bin/install-observability.sh
```

## Component-to-script mapping

The unified installer maps components to implementations in
`genestack-observability`:

| Component | Implementation |
|---|---|
| `monitoring-rgw-storage` | `bin/setup-monitoring-rgw-storage.sh` |
| `kube-prometheus-stack` | `bin/install-kube-prometheus-stack.sh` |
| `prometheus-pushgateway` | `bin/install-prometheus-pushgateway.sh` |
| `barbican-exporter` | `bin/install-barbican-exporter.sh` |
| `openstack-exporter` | `bin/install-openstack-exporter.sh` |
| `tempo` | `bin/install-tempo.sh` |
| `loki` | `bin/install-loki.sh` |
| `opentelemetry-kube-stack` | `bin/install-opentelemetry-kube-stack.sh` |
| `grafana` | `bin/install-grafana.sh` |
| `prometheus-rules` | `bin/install-prometheus-rules.sh` |
| `loki-rules` | `bin/loki-sync-rules.sh` |

`install-lokitool.sh` is a dependency installer and is not represented as a
service component.

## Bootstrap

The canonical first-run command is:

```bash
/opt/genestack/bin/bootstrap-observability.sh
```

The equivalent implementation can also be invoked from the observability
checkout after it exists:

```bash
/opt/genestack-observability/bin/bootstrap-observability.sh
```

Bootstrap performs the following high-level workflow:

1. verify the expected Genestack paths;
2. create and ownership-correct `/opt/genestack-observability` when needed;
3. clone or update `genestack-observability` as the repository owner;
4. synchronize and initialize repository submodules;
5. create the Helm and Kustomize integration symlinks;
6. seed only missing Helm/Kustomize site service configuration;
7. prepare and apply observability Gateway API routes when route management is
   enabled;
8. invoke the unified observability installer;
9. reconcile observability routes again after component installation.

Bootstrap does not create `/etc/genestack/observability-components.yaml`.

The clone URL is:

```text
git@github.com:rackerlabs/genestack-observability.git
```

Conceptually, the initial checkout is:

```bash
sudo mkdir -p /opt/genestack-observability
sudo chown ubuntu:ubuntu /opt/genestack-observability

git clone \
  --recurse-submodules \
  git@github.com:rackerlabs/genestack-observability.git \
  /opt/genestack-observability
```

The bootstrap performs the privilege and ownership handling automatically; the
literal owner/group above is only illustrative.

For an existing checkout, bootstrap performs the equivalent of:

```bash
git -C /opt/genestack-observability pull --ff-only

git -C /opt/genestack-observability submodule sync --recursive

git -C /opt/genestack-observability submodule update \
  --init \
  --recursive
```

`submodule sync --recursive` keeps local submodule URLs aligned with
`.gitmodules` before the recursive update.

To configure the repository, links, site service configuration, and routes
without installing services:

```bash
/opt/genestack/bin/bootstrap-observability.sh --no-install
```

To avoid pulling updates to an existing observability checkout:

```bash
/opt/genestack/bin/bootstrap-observability.sh --no-update
```

To skip observability Gateway API route seeding/apply:

```bash
/opt/genestack/bin/bootstrap-observability.sh --no-routes
```

### Gateway API handling

When route management is enabled, bootstrap seeds missing observability route
files from:

```text
/opt/genestack-observability/etc/gateway-api/routes
```

into the site-owned location:

```text
/etc/genestack/gateway-api/routes
```

Existing route files are preserved. Listener templates are handled similarly
when an observability route references a listener that is not already present.

A gateway domain can be supplied with:

```bash
OBSERVABILITY_GATEWAY_DOMAIN=example.internal \
  /opt/genestack/bin/bootstrap-observability.sh
```

If not supplied, bootstrap may derive the domain from `GATEWAY_DOMAIN`,
`/etc/genestack/envoy-gateways.yaml`, or a wildcard Gateway listener.

When Envoy multi-gateway config mode is detected through
`/etc/genestack/envoy-gateways.yaml`, that configuration owns route rendering
and the legacy route-seeding/apply path is skipped.

## Unified installation

The canonical Genestack entrypoint is:

```bash
/opt/genestack/bin/install-observability.sh
```

The equivalent observability-repository entrypoint is:

```bash
/opt/genestack-observability/bin/install-observability.sh
```

With no component arguments, the installer installs all components enabled in
the resolved component configuration using `install_order`:

```bash
/opt/genestack/bin/install-observability.sh
```

Individual components can also be installed explicitly by name:

```bash
/opt/genestack/bin/install-observability.sh loki
```

Multiple components can be requested in one invocation and are installed in
the order supplied:

```bash
/opt/genestack/bin/install-observability.sh \
  kube-prometheus-stack \
  prometheus-rules
```

Other examples:

```bash
/opt/genestack/bin/install-observability.sh grafana

/opt/genestack/bin/install-observability.sh \
  tempo \
  loki \
  loki-rules
```

An explicitly named component is installed even if its boolean value is
`false` in the component configuration. This makes targeted repair, testing,
and upgrade operations possible without temporarily editing the configuration.

List known components and their configured enabled state with:

```bash
/opt/genestack/bin/install-observability.sh --list
```

Display usage information with:

```bash
/opt/genestack/bin/install-observability.sh --help
```

Regardless of which copy is executed, actual service installers are resolved
from:

```text
/opt/genestack-observability/bin
```

This preserves a clean ownership boundary between the projects.

## lokitool

Loki rule synchronization requires the standalone `lokitool` client on the
overseer.

The desired version is pinned at:

```text
/opt/genestack-observability/versions/lokitool
```

The current pin is:

```text
3.7.8
```

Install or reconcile the pinned binary with:

```bash
/opt/genestack-observability/bin/install-lokitool.sh
```

The installer replaces an installed `lokitool` when its version does not match
the pin.

When `loki-rules` is requested and `lokitool` is absent,
`install-observability.sh` invokes the installer automatically. The Loki rule
sync script also verifies that the installed client supports
`--namespaces-regex`, which is required for Genestack namespace ownership.

## Prometheus rules

Prometheus alerting rules live at:

```text
/opt/genestack-observability/alerts/prometheus-alerts
```

Recording rules live at:

```text
/opt/genestack-observability/alerts/recording
```

Both are deployed by:

```text
/opt/genestack-observability/bin/install-prometheus-rules.sh
```

as native `PrometheusRule` resources.

The previous generated `alerting_rules.yaml` workflow is not required by the
new deployment model.

## Loki deployment modes

Production and fresh lab environments intentionally use different Loki storage
backends while sharing the same higher-level deployment tooling.

### Production

Production continues to use the regional Loki configuration and object storage
such as Swift. The normal rule synchronization path reaches Loki through the
regional HTTPRoute/Gateway endpoint.

### Fresh lab

A fresh lab can be self-contained and does not require Swift, MinIO, or another
external object store. The lab deployment uses a SingleBinary Loki with
filesystem/PVC-backed storage and a gateway service.

The lab Ruler must remain API-writable because Loki rules are synchronized by
`lokitool`; sidecar ConfigMap rule loading is not used. Site values must
explicitly neutralize inherited production-style ruler/sidecar settings when
necessary because Helm deep-merges the base, global, and site values files.

## Loki rules

Loki rules live at:

```text
/opt/genestack-observability/alerts/loki-alerts
```

Each file contains an explicit Ruler namespace:

```yaml
namespace: genestack-octavia-health-manager

groups:
  - name: octavia-health-manager-alerts
    rules:
      ...
```

The synchronization implementation is:

```text
/opt/genestack-observability/bin/loki-sync-rules.sh
```

The rule source remains owned by the observability repository.

Synchronization is constrained to namespaces matching:

```text
^genestack-
```

using `lokitool --namespaces-regex`. This prevents an unrestricted sync from
reconciling Ruler namespaces owned outside this repository.

### Loki endpoint selection

`loki-sync-rules.sh` resolves the endpoint in this order:

1. explicit `LOKI_ADDRESS`;
2. the production HTTPRoute/Gateway endpoint;
3. a temporary local `kubectl port-forward` to `monitoring/loki-gateway`.

The production route is discovered from:

```text
monitoring/internal-loki-gateway-route
```

The script inspects the referenced Gateway listener to determine the protocol
and port.

An explicit endpoint always wins:

```bash
LOKI_ADDRESS=https://loki.example.internal \
  /opt/genestack/bin/install-observability.sh loki-rules
```

If no explicit address is supplied and the discovered production endpoint
cannot be reached from the overseer, the script starts a temporary lab
port-forward automatically. The local port search starts at `13101` and moves
to subsequent ports when necessary. The temporary process is cleaned up when
the script exits.

An explicit `LOKI_ADDRESS` does not silently fall back to another endpoint if
it is wrong or unavailable. This prevents an operator-specified production
address from being masked by an unintended local path.

### Ruler readiness

A freshly installed Loki gateway can become reachable before its Loki upstream
is ready. During this interval nginx may return `502`, `503`, or `504`.

The rule sync waits for the Ruler API before running `lokitool`. The default
readiness behavior is:

```text
LOKI_READY_TIMEOUT=180
LOKI_READY_INTERVAL=5
```

Connection failures and HTTP `502`, `503`, and `504` are treated as transient
and retried within that window.

A successful `2xx` response is considered ready. Loki's empty-Ruler response
of HTTP `404` with `no rule groups found` is also treated as a valid ready
state. Real application/configuration errors such as HTTP `400` or an
unexpected `404` fail instead of being hidden by retries.

The readiness window can be adjusted for a slow environment:

```bash
LOKI_READY_TIMEOUT=300 \
LOKI_READY_INTERVAL=5 \
  /opt/genestack/bin/install-observability.sh loki-rules
```

### Rule synchronization

After the Ruler API is ready, the script runs:

```bash
lokitool rules diff \
  --rule-dirs=/opt/genestack-observability/alerts/loki-alerts \
  --namespaces-regex='^genestack-' \
  --verbose

lokitool rules sync \
  --rule-dirs=/opt/genestack-observability/alerts/loki-alerts \
  --namespaces-regex='^genestack-'
```

No regional hostname, Service IP, NodePort, or manually maintained lab
port-forward needs to be hardcoded into Genestack.

## Updating observability

The normal update path is to rerun bootstrap:

```bash
/opt/genestack/bin/bootstrap-observability.sh
```

This updates the observability checkout, synchronizes submodules, preserves
existing site-owned service configuration, reconciles integration links and
routes, and then runs the unified installer.

For manual repository-only maintenance:

```bash
git -C /opt/genestack-observability pull --ff-only

git -C /opt/genestack-observability submodule sync --recursive

git -C /opt/genestack-observability submodule update \
  --init \
  --recursive
```

Review the effective component configuration with:

```bash
/opt/genestack/bin/install-observability.sh --list
```

If a site component override exists, it can be inspected directly:

```bash
if [[ -f /etc/genestack/observability-components.yaml ]]; then
  cat /etc/genestack/observability-components.yaml
fi
```

Then reconcile enabled services with:

```bash
/opt/genestack/bin/install-observability.sh
```

Individual observability implementations can still be invoked directly when
needed:

```bash
/opt/genestack-observability/bin/install-loki.sh
/opt/genestack-observability/bin/install-grafana.sh
/opt/genestack-observability/bin/install-opentelemetry-kube-stack.sh
```

## Verification

Verify repository ownership:

```bash
stat -c '%U:%G %n' /opt/genestack-observability
```

Verify repository integration:

```bash
readlink -f /opt/genestack/base-helm-configs/observability
readlink -f /opt/genestack/base-kustomize/observability
```

Expected:

```text
/opt/genestack-observability/helm-configs
/opt/genestack-observability/kustomize
```

Review resolved component state:

```bash
/opt/genestack/bin/install-observability.sh --list
```

Review monitoring Helm releases:

```bash
helm list -n monitoring
```

Verify custom Prometheus rules:

```bash
kubectl -n monitoring get prometheusrules \
  -l app.kubernetes.io/name=genestack-prometheus-rules
```

Verify Loki rule tooling:

```bash
lokitool version
```

Verify Loki rules through the normal synchronization path:

```bash
/opt/genestack/bin/install-observability.sh loki-rules
```

For a lab, successful output should show the temporary gateway port-forward
being created when necessary and stopped after synchronization.

## Ownership summary

```text
Genestack
  Shared operator-facing observability orchestration entrypoints.
  Core OpenStack/infrastructure secret ownership.

genestack-observability
  Actual observability service installers.
  Helm configuration.
  Kustomize configuration.
  Gateway API observability route/listener templates.
  Prometheus alerting rules.
  Prometheus recording rules.
  Loki rules.
  Observability support tooling.
  Pinned tool versions.

/etc/genestack
  Site-owned Helm/Kustomize overrides and rendered route configuration.
  Optional observability-components.yaml override.
  Optional observability-secrets.yaml generated by observability tooling.

/opt/genestack/base-helm-configs/observability
/opt/genestack/base-kustomize/observability
  Stable integration paths into genestack-observability.
```

`monitoring-common.sh` is responsible for ensuring required monitoring runtime
Secrets are present in the namespaces that consume them. It is separate from
the optional file-based `/etc/genestack/observability-secrets.yaml` generation
workflow.
