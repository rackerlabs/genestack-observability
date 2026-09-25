# Genestack Observability

Monitoring and observability tooling, configuration, dashboards, exporters, and alerting for [Genestack](https://github.com/rackerlabs/genestack).

This repository owns the observability-specific Helm/Kustomize configuration, service installers, Prometheus alerting and recording rules, Loki alert rules, and supporting deployment tooling used by Genestack environments.

## Documentation

- [Deploy Genestack Observability on an Overseer](docs/genestack-observability-deployment.md)
- [Alerting and Recording Rules](docs/genestack-observability-alerts-and-rules.md)
- [Genestack documentation](https://docs.rackspacecloud.com/)
- [Genestack repository](https://github.com/rackerlabs/genestack)

## Deployment

The normal Genestack entrypoint is:

```bash
/opt/genestack/bin/bootstrap-observability.sh
```

After bootstrap, enabled observability components can be reconciled with:

```bash
/opt/genestack/bin/install-observability.sh
```

Individual components can also be installed or repaired explicitly:

```bash
/opt/genestack/bin/install-observability.sh loki
/opt/genestack/bin/install-observability.sh prometheus-rules
/opt/genestack/bin/install-observability.sh loki-rules
```

See the [deployment guide](docs/genestack-observability-deployment.md) for repository integration, configuration precedence, secrets, lab behavior, and production deployment details.

## Alerting and recording rules

Prometheus alerting and recording rules are maintained as individual source files under:

```text
alerts/prometheus-alerts/
alerts/recording/
```

They are deployed as native `PrometheusRule` resources.

Loki alert rules are maintained under:

```text
alerts/loki-alerts/
```

and synchronized to the Loki Ruler API with `lokitool`.

See [Alerting and Recording Rules](docs/genestack-observability-alerts-and-rules.md) for the rule formats, namespace conventions, deployment workflow, and Loki Ruler requirements.

## Legacy rule combiners

The repository also retains two helper utilities for older deployments that expect generated or combined rule files.

### `combiner.py`

`combiner.py` recursively reads Prometheus rule files containing `additionalPrometheusRulesMap`, normalizes them, and writes a single combined YAML file.

This is useful for legacy deployments that still expect one generated `alerting_rules.yaml` rather than native `PrometheusRule` resources.

Example:

```bash
python3 combiner.py \
  alerts/prometheus-alerts \
  alerts/recording \
  -o alerting_rules.yaml
```

The script requires `ruamel.yaml`:

```bash
python3 -m pip install ruamel.yaml
```

### `loki-combiner.py`

`loki-combiner.py` recursively reads Loki rule files and generates a multi-document YAML file containing one labeled `ConfigMap` per rule file.

This supports legacy Loki deployments that use ConfigMap/sidecar rule discovery instead of synchronizing rules through the Loki Ruler API.

Example:

```bash
python3 loki-combiner.py \
  alerts/loki-alerts \
  -o loki-rules.yaml
```

By default the generated ConfigMaps:

- use the `monitoring` namespace;
- are labeled `loki_rule: "1"`;
- preserve each source rule file as ConfigMap data.

The modern deployment path does **not** require either combiner. They remain available for compatibility with older environments and migration workflows.
