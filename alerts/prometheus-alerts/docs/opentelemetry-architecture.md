# OpenTelemetry Configuration Architecture

## Overview

This document provides visual diagrams and detailed breakdowns of your OpenTelemetry collector configuration with full telemetry (logs, metrics, traces) enabled.

## Architecture Diagrams

### Simplified Architecture
See `otel-simplified-diagram.mmd` for a high-level overview showing:
- 📊 Three telemetry sources (Traces, Metrics, Logs)
- 🔧 Collector components (Receivers, Processors, Exporters)
- 💾 Storage backends (Tempo, Prometheus, Loki)
- 📺 Grafana visualization layer

### Detailed Architecture
See `otel-architecture-diagram.mmd` for comprehensive details including:
- All individual data sources
- Complete receiver configurations with ports
- All processors and their functions
- Pipeline flows
- Storage backend connections

## Key Components Breakdown

### 1. Receivers (Data Ingestion)

#### Trace Receivers
| Receiver | Port | Protocol | Purpose |
|----------|------|----------|---------|
| OTLP gRPC | 4317 | gRPC | Modern trace ingestion |
| OTLP HTTP | 4318 | HTTP | Modern trace ingestion (HTTP) |
| Jaeger gRPC | 14250 | gRPC | Legacy Jaeger spans |
| Jaeger HTTP | 14268 | HTTP | Legacy Jaeger spans (HTTP) |
| Jaeger Compact | 6831 | UDP | Legacy Jaeger compact format |
| Zipkin | 9411 | HTTP | Legacy Zipkin spans |

#### Metrics Receivers
| Receiver | Source | Data Collected | Status |
|----------|--------|----------------|--------|
| OTLP | Applications | Custom app metrics via OTLP | ✅ Active |
| Host Metrics | Node | CPU, memory, disk, network, filesystem, paging, processes | ✅ Active |
| Kubelet Stats | Kubelet | Pod/container resource usage | ⚠️ Disabled (see note below) |

**Note on Kubelet Stats**: The kubeletstats receiver is currently disabled to avoid duplicate sample errors in Prometheus. Instead, pod and container metrics are collected via Prometheus directly scraping kubelet's cAdvisor endpoint, which provides `container_*` metrics with equivalent functionality.

#### Logs Receivers
| Receiver | Path Pattern | Service |
|----------|--------------|---------|
| filelog/k8s_containers | `/var/log/pods/*/*/*.log` | All K8s pods (excluding OpenStack) |
| filelog/openstack | `/var/log/{service}/*.log`<br>`/var/log/pods/*/{service}-*/*.log` | **All 17 OpenStack services** (consolidated) |
| k8sobjects | Kubernetes Events API | Kubernetes cluster events |

**OpenStack Services Covered** (single consolidated receiver):
- Nova (compute)
- Neutron (networking)
- Cinder (block storage)
- Keystone (identity)
- Glance (images)
- Horizon (dashboard + Apache logs)
- Heat (orchestration)
- Swift (object storage)
- Octavia (load balancer)
- Placement (API)
- Manila (shared filesystems)
- Ironic (bare metal)
- Barbican (secrets)
- Ceilometer (telemetry)
- Gnocchi (time-series)
- Skyline (dashboard)
- Trove (DBaaS)

**Total**: 3 log receivers (K8s containers, OpenStack consolidated, K8s events)

### 2. Processors (Data Enrichment)

| Processor | Function | Configuration |
|-----------|----------|---------------|
| **memory_limiter** | Prevents OOM | 90% limit, 25% spike |
| **batch** | Batches telemetry | 1000 items, 10s timeout, max 1500 |
| **k8sattributes** | Adds K8s metadata | Pod, namespace, deployment, labels, annotations |
| **resourcedetection/env** | Detects environment | env, k8snode, system detectors |
| **attributes/add-node-labels** | Adds node identity | k8s_node_name, host_name, service_instance_id |
| **resource/hostname** | Ensures hostname | Copies k8s.node.name to host.name |
| **attributes** | Adds cluster info | Cluster name: "openstack-genestack-k8s-cluster", environment: "genestack" |
| **resource/openstack** | Tags OpenStack logs | `service.namespace=openstack` |
| **resource/k8s** | Tags K8s logs | `service.namespace=kube-system` |
| **resource/k8s-events** | Tags K8s events | `log_type=k8s-event` |
| **resource/loki-labels** | Maps OTel → Loki labels | namespace, pod, node, container, cluster, deployment, etc. |

### 3. Exporters (Data Export)

| Exporter | Destination | Port/Endpoint | Telemetry Type | Protocol |
|----------|-------------|---------------|----------------|----------|
| **otlp/tempo** | Tempo | `tempo.grafana.svc.cluster.local:4317` | Traces | OTLP/gRPC |
| **prometheusremotewrite** | Prometheus | `prometheus:9090/api/v1/write` | Metrics | Prometheus Remote Write |
| **otlphttp/loki** | Loki | `loki-gateway.grafana.svc.cluster.local/otlp` | Logs | OTLP/HTTP |
| **debug** | Stdout/logs | N/A | All | Verbose (sampled: 2 initial, 1/1000 thereafter) |

### 4. Pipelines (Data Flow)

#### Traces Pipeline
```
Sources → Receivers → Processors → Exporters
  ↓          ↓           ↓             ↓
Apps     OTLP/Jaeger  k8sattributes  Tempo
         /Zipkin      resource       Debug
                      batch
                      memory_limiter
```

#### Metrics Pipeline
```
Sources → Receivers → Processors → Exporters
  ↓          ↓           ↓             ↓
Apps       OTLP         attributes/    Prometheus
Nodes      HostMetrics  add-node-      (Remote Write)
                        labels         Debug
                        resourcedetec
                        tion/env
                        k8sattributes
                        resource/
                        hostname
                        memory_limiter
                        batch

Note: kubeletstats receiver disabled to avoid duplicates.
      Pod/container metrics collected via Prometheus scraping
      kubelet/cAdvisor instead (container_* metrics).
```

#### Logs/K8s Pipeline
```
Sources → Receivers → Processors → Exporters
  ↓          ↓           ↓             ↓
K8s Pods  filelog/k8s  memory_limiter Loki
                       k8sattributes  Debug
                       batch
                       resourcedetec
                       tion/env
                       attributes
                       resource/
                       loki-labels
```

#### Logs/K8s Events Pipeline
```
Sources → Receivers → Processors → Exporters
  ↓          ↓           ↓             ↓
K8s API   k8sobjects   memory_limiter Loki
Events                 resource/      Debug
                       k8s-events
                       k8sattributes
                       batch
                       resourcedetec
                       tion/env
                       attributes
                       resource/
                       loki-labels
```

#### Logs/OpenStack Pipeline (Consolidated)
```
Sources → Receivers → Processors → Exporters
  ↓          ↓           ↓             ↓
17 OS     filelog/     memory_limiter Loki
Services  openstack    k8sattributes  Debug
(single                batch
receiver)              attributes
                       resource/
                       openstack
                       resource/
                       loki-labels

Note: Single consolidated receiver for all OpenStack services.
      Service name extracted dynamically from log file path.
      Includes multiline recombination and CRI unwrapping.
```

## Port Summary

### Exposed Ports on Collector Service

| Port | Protocol | Purpose |
|------|----------|---------|
| 4317 | gRPC | OTLP receiver (traces & metrics) |
| 4318 | HTTP | OTLP receiver (traces & metrics) |
| 14250 | gRPC | Jaeger receiver |
| 14268 | HTTP | Jaeger receiver |
| 6831 | UDP | Jaeger compact receiver |
| 9411 | HTTP | Zipkin receiver |
| 8888 | HTTP | Collector internal metrics endpoint |

## Data Flow Summary

### Traces
1. **Applications** send traces via OTLP/Jaeger/Zipkin → **Collector receivers**
2. **Processors** enrich with K8s metadata, batch, limit memory
3. **Tempo exporter** sends to **Grafana Tempo**
4. **Grafana** queries Tempo for trace visualization

### Metrics
1. **Via OTel Collectors (Remote Write)**:
   - Applications send OTLP metrics → **Collector receivers**
   - **Host metrics receiver** collects node-level metrics (CPU, memory, disk, network, filesystem)
   - **Processors** add node labels, enrich with K8s metadata, batch, limit memory
   - **Prometheus remote write exporter** sends to **Prometheus**

2. **Via Prometheus Scraping (Direct)**:
   - **Kubernetes components** (API server, scheduler, controller manager, etc.) expose Prometheus metrics
   - **Kubelet/cAdvisor** exposes pod and container metrics (`container_*` prefix)
   - **Node exporter** exposes detailed node metrics (`node_*` prefix)
   - **Kube-state-metrics** exposes Kubernetes object state (`kube_*` prefix)
   - **Prometheus** scrapes these endpoints directly via ServiceMonitors

3. **Grafana** queries Prometheus for metrics dashboards

**Note**: Pod/container metrics come from Prometheus scraping kubelet/cAdvisor (not from OTel kubeletstats receiver, which is disabled to avoid duplicate samples).

### Logs
1. **Containers** write logs to `/var/log/pods/` (K8s) or service-specific paths (OpenStack)
2. **Filelog receivers** tail and parse logs
3. **Processors** enrich with metadata, batch, limit memory
4. **Loki exporter** sends to **Grafana Loki**
5. **Grafana** queries Loki for log exploration

## Auto-Instrumentation

Applications can be automatically instrumented without code changes:

```yaml
# Add annotation to namespace or pod
instrumentation.opentelemetry.io/inject-python: "true"
instrumentation.opentelemetry.io/inject-java: "true"
instrumentation.opentelemetry.io/inject-nodejs: "true"
instrumentation.opentelemetry.io/inject-dotnet: "true"
instrumentation.opentelemetry.io/inject-go: "true"
```

The operator will inject instrumentation that sends traces to the collector at `collector-daemon:4317`.

## Resource Limits

### Collector DaemonSet
- **CPU Request**: 2048m (2 cores)
- **CPU Limit**: 4096m (4 cores)
- **Memory Request**: 2048Mi (2 GiB)
- **Memory Limit**: 4096Mi (4 GiB)

### Processor Limits
- **Memory Limiter**: 90% of allocated memory with 25% spike allowance
- **Batch Size**: 1000 telemetry items
- **Batch Max Size**: 1500 items
- **Batch Timeout**: 10 seconds

## Key Metrics to Monitor

Monitor these collector metrics at `:8888/metrics`:

- `otelcol_receiver_accepted_spans_total` - Traces received
- `otelcol_receiver_accepted_metric_points_total` - Metrics received
- `otelcol_receiver_accepted_log_records_total` - Logs received
- `otelcol_exporter_sent_spans_total` - Traces exported
- `otelcol_exporter_sent_metric_points_total` - Metrics exported
- `otelcol_exporter_sent_log_records_total` - Logs exported
- `otelcol_processor_batch_batch_send_size_bucket` - Batch sizes
- `otelcol_exporter_queue_size` - Export queue depth

## Storage Backends

### Grafana Tempo
- **Purpose**: Distributed tracing backend
- **Endpoint**: `tempo-distributor.grafana.svc.cluster.local:4317`
- **Protocol**: OTLP/gRPC
- **Data**: Trace spans with full context

### Prometheus
- **Purpose**: Time-series metrics database
- **Endpoints**:
  - Remote Write: `prometheus-server/api/v1/write`
  - Scrape: collector `:8889/metrics`
- **Protocol**: Prometheus Remote Write + HTTP scrape
- **Data**: Metrics time-series

### Grafana Loki
- **Purpose**: Log aggregation system
- **Endpoint**: `loki-gateway.grafana.svc.cluster.local/otlp`
- **Protocol**: OTLP/HTTP
- **Data**: Structured logs with labels

## Correlation Features

All three telemetry signals are correlated via common attributes:

- `k8s.namespace.name`
- `k8s.pod.name`
- `k8s.deployment.name`
- `service.name`
- `service.namespace`

This enables:
- 🔍 **Trace → Logs**: Click on a trace span to see related logs
- 📊 **Metrics → Traces**: See traces for pods with high CPU/memory
- 📝 **Logs → Traces**: Find traces associated with error logs

## Viewing the Diagrams

### Option 1: Mermaid Live Editor
1. Visit https://mermaid.live
2. Copy the content from `otel-simplified-diagram.mmd` or `otel-architecture-diagram.mmd`
3. Paste into the editor
4. View and export the diagram

### Option 2: VS Code
1. Install "Markdown Preview Mermaid Support" extension
2. Create a markdown file with:
   ```markdown
   ```mermaid
   [paste diagram content here]
   ```
   ```
3. Preview the markdown file

### Option 3: GitHub/GitLab
Both platforms render Mermaid diagrams automatically in markdown files.

## Summary

Your OpenTelemetry stack now provides:

✅ **3 Log Receivers**: K8s containers + K8s events + OpenStack (consolidated 17 services)
✅ **6 Trace Receivers**: OTLP (gRPC + HTTP) + Jaeger (gRPC + HTTP + Compact) + Zipkin
✅ **2 Active Metrics Receivers**: OTLP + Host Metrics (kubeletstats disabled)
✅ **11 Processors**: Node labeling, K8s enrichment, batching, resource detection, Loki label mapping
✅ **4 Exporters**: Tempo + Prometheus Remote Write + Loki + Debug
✅ **5 Pipelines**: Traces, Metrics, Logs (K8s), Logs (K8s Events), Logs (OpenStack)
✅ **3 Storage Backends**: Tempo, Prometheus, Loki
✅ **1 Unified Frontend**: Grafana with full correlation
✅ **Additional Metrics**: Prometheus directly scrapes K8s components, kubelet/cAdvisor, node-exporter, kube-state-metrics

**Key Architecture Decisions**:
- **Consolidated OpenStack Logging**: Single receiver for all 17 services with dynamic service name extraction (reduced config by ~700 lines)
- **Hybrid Metrics Collection**: OTel collectors for node-level metrics + OTLP apps, Prometheus scraping for K8s components and pod/container metrics
- **kubeletstats Disabled**: Avoided duplicate sample errors by using Prometheus cAdvisor scraping instead
- **Enhanced Label Propagation**: Comprehensive Loki label mapping for better log querying

**Total observability coverage**: Comprehensive logging, metrics, and distributed tracing for both Kubernetes and OpenStack infrastructure! 🎉
