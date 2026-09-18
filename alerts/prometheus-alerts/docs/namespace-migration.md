# Monitoring Stack Migration Guide

Complete guide for migrating the full observability stack (OpenTelemetry, Prometheus, Loki, Grafana) from multiple namespaces to a centralized `monitoring` namespace.

---

## Table of Contents

1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Migration Architecture](#migration-architecture)
4. [Pre-Migration Checklist](#pre-migration-checklist)
5. [Step-by-Step Migration](#step-by-step-migration)
6. [Post-Migration Verification](#post-migration-verification)
7. [Rollback Procedure](#rollback-procedure)
8. [Troubleshooting](#troubleshooting)

---

## Overview

### What This Migration Does

This migration consolidates the observability stack into a single `monitoring` namespace for better organization, simplified RBAC, and easier management.

**Before Migration**:
```
├── opentelemetry (namespace)
│   └── OpenTelemetry Collectors
├── prometheus (namespace)
│   └── Prometheus + Alertmanager
├── grafana (namespace)
│   ├── Grafana
│   ├── Loki
│   └── Tempo
└── openstack (namespace)
    └── Database credentials (secrets)
```

**After Migration**:
```
└── monitoring (namespace)
    ├── OpenTelemetry Collectors
    ├── Prometheus + Alertmanager
    ├── Loki
    ├── Tempo
    ├── Grafana
    └── Database credentials (copied secrets)
```

### Why Migrate?

- ✅ **Simplified Access Control**: Single namespace for all monitoring RBAC
- ✅ **Easier Service Discovery**: All monitoring services in one namespace
- ✅ **Reduced Configuration**: Simpler endpoint URLs (no cross-namespace references)
- ✅ **Better Resource Management**: Unified resource quotas and limits
- ✅ **Cleaner Organization**: Logical grouping of observability components

### What Gets Migrated

| Component | From Namespace | To Namespace | Data Loss? |
|-----------|---------------|--------------|------------|
| OpenTelemetry | `opentelemetry` | `monitoring` | No (stateless) |
| Prometheus | `prometheus` | `monitoring` | **Yes** (historical metrics) |
| Loki | `grafana` | `monitoring` | **Yes** (historical logs) |
| Tempo | `grafana` | `monitoring` | **Yes** (historical traces) |
| Grafana | `grafana` | `monitoring` | **Yes** (dashboards, datasources) |
| Secrets | `openstack` | `monitoring` | No (copied) |

⚠️ **Important**: This migration will result in **loss of historical data** (metrics, logs, traces) because PVCs cannot be moved across namespaces. Plan accordingly.

---

## Prerequisites

### Required Access

- Cluster admin or namespace admin permissions
- Access to `openstack`, `opentelemetry`, `prometheus`, and `grafana` namespaces
- Ability to create the `monitoring` namespace

### Required Tools

```bash
# Install required CLI tools
kubectl version  # Kubernetes CLI
helm version     # Helm 3
yq --version     # YAML processor (v4+)
k9s version      # Optional but recommended for PVC cleanup
```

### Backup Important Data

Before proceeding, backup critical configurations:

```bash
# Create backup directory
mkdir -p monitoring-migration-backup
cd monitoring-migration-backup

# Backup Grafana dashboards
kubectl -n grafana get configmap -l grafana_dashboard -o yaml > grafana-dashboards-backup.yaml

# Backup Grafana datasources
kubectl -n grafana get secret grafana-datasources -o yaml > grafana-datasources-backup.yaml

# Backup Prometheus recording rules
kubectl -n prometheus get prometheusrule -o yaml > prometheus-rules-backup.yaml

# Backup Prometheus alerting rules
helm -n prometheus get values kube-prometheus-stack > prometheus-values-backup.yaml

# Backup current OpenTelemetry config
helm -n opentelemetry get values opentelemetry-kube-stack > otel-values-backup.yaml

# Backup Loki config
helm -n grafana get values loki > loki-values-backup.yaml

# List all PVCs (for reference)
kubectl -n prometheus get pvc > prometheus-pvcs.txt
kubectl -n grafana get pvc > grafana-pvcs.txt
```

### Downtime Expectations

| Component | Downtime | Impact |
|-----------|----------|--------|
| OpenTelemetry | ~5 minutes | Telemetry collection paused |
| Prometheus | ~10 minutes | No metric scraping, alerts paused |
| Loki | ~10 minutes | No log ingestion |
| Grafana | ~5 minutes | Dashboards unavailable |
| **Total** | ~30 minutes | Full observability outage |

⚠️ **Schedule this migration during a maintenance window!**

---

## Migration Architecture

### Network Flow Changes

**Before (Cross-Namespace)**:
```
┌─────────────────────────────────────────────────────────────────┐
│ OpenTelemetry Collectors (opentelemetry namespace)              │
│                                                                 │
│  exporters:                                                     │
│    prometheusremotewrite:                                       │
│      endpoint: kube-prometheus-stack-prometheus.prometheus...   │
│    otlp/tempo:                                                  │
│      endpoint: tempo.grafana.svc.cluster.local:4317             │
│    otlphttp/loki:                                               │
│      endpoint: http://loki-gateway.grafana.svc.cluster.local    │
└─────────────────────────────────────────────────────────────────┘
           │                        │                    │
           ▼                        ▼                    ▼
    ┌──────────────┐      ┌──────────────┐    ┌──────────────┐
    │ Prometheus   │      │    Tempo     │    │     Loki     │
    │ (prometheus) │      │  (grafana)   │    │  (grafana)   │
    └──────────────┘      └──────────────┘    └──────────────┘
```

**After (Same Namespace)**:
```
┌─────────────────────────────────────────────────────────────────┐
│                    monitoring namespace                         │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ OpenTelemetry Collectors                                 │   │
│  │                                                          │   │
│  │  exporters:                                              │   │
│  │    prometheusremotewrite:                                │   │
│  │      endpoint: kube-prometheus-stack-prometheus:9090     │   │
│  │    otlp/tempo:                                           │   │
│  │      endpoint: tempo:4317                                │   │
│  │    otlphttp/loki:                                        │   │
│  │      endpoint: http://loki-gateway/otlp                  │   │
│  └───────────────┬──────────────┬──────────────┬────────────┘   │
│                  │              │              │                │
│                  ▼              ▼              ▼                │
│         ┌──────────────┐ ┌──────────────┐ ┌──────────────┐      │
│         │ Prometheus   │ │    Tempo     │ │     Loki     │      │
│         └──────────────┘ └──────────────┘ └──────────────┘      │
│                                   │                             │
│                                   ▼                             │
│                          ┌──────────────┐                       │
│                          │   Grafana    │                       │
│                          └──────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

**Key Benefits**:
- Simpler service names (no `.namespace.svc.cluster.local` needed)
- Faster DNS resolution
- Easier troubleshooting
- Single network policy for entire stack

---

## Pre-Migration Checklist

Before starting, verify these conditions:

```bash
# 1. Check that monitoring namespace doesn't exist
kubectl get namespace monitoring
# Expected: Error from server (NotFound): namespaces "monitoring" not found

# 2. Verify all components are running
kubectl -n opentelemetry get pods
kubectl -n prometheus get pods
kubectl -n grafana get pods

# 3. Check available storage (for new PVCs)
kubectl get pv | grep Available

# 4. Verify install scripts exist
ls -la bin/install-opentelemetry-kube-stack.sh
ls -la bin/install-kube-prometheus-stack.sh
ls -la bin/install-loki.sh
ls -la bin/install-grafana.sh

# 5. Verify values files are updated for monitoring namespace
grep -r "namespace: monitoring" base-kustomize/
```

✅ **All checks passed? Proceed to migration.**

---

## Step-by-Step Migration

### Phase 0: Preparation

#### Create Monitoring Namespace

```bash
# Create the new namespace
kubectl create namespace monitoring

# Label it appropriately
kubectl label namespace monitoring \
  name=monitoring \
  monitoring=enabled

# Verify
kubectl get namespace monitoring
```

#### Copy Required Secrets

These secrets are needed by OpenTelemetry deployment collector to scrape database metrics:

**1. RabbitMQ Credentials**

```bash
# Copy RabbitMQ secret from openstack to monitoring namespace
kubectl -n openstack get secret rabbitmq-default-user -o yaml \
  | yq 'del(.metadata.creationTimestamp, .metadata.uid, .metadata.ownerReferences, .metadata.resourceVersion, .metadata.namespace)' \
  | kubectl apply --namespace monitoring -f -

# Verify
kubectl -n monitoring get secret rabbitmq-default-user
```

**2. PostgreSQL Credentials**

```bash
# Copy PostgreSQL secret from openstack to monitoring namespace
kubectl get secret postgres.postgres-cluster.credentials.postgresql.acid.zalan.do \
  -n openstack -o yaml \
  | sed 's/namespace: openstack/namespace: monitoring/' \
  | kubectl apply -f -

# Verify
kubectl -n monitoring get secret postgres.postgres-cluster.credentials.postgresql.acid.zalan.do
```

**3. MariaDB Monitoring Credentials**

```bash
# Copy MariaDB monitoring secret from openstack to monitoring namespace
kubectl get secret mariadb-monitoring \
  -n openstack -o yaml \
  | sed 's/namespace: openstack/namespace: monitoring/' \
  | kubectl apply -f -

# Verify
kubectl -n monitoring get secret mariadb-monitoring
```

**Verification**

```bash
# List all copied secrets
kubectl -n monitoring get secrets

# Should see:
# NAME                                                           TYPE     DATA   AGE
# rabbitmq-default-user                                          Opaque   3      30s
# postgres.postgres-cluster.credentials.postgresql.acid.zalan.do Opaque   2      20s
# mariadb-monitoring                                             Opaque   1      10s
```

---

### Phase 1: Migrate OpenTelemetry

OpenTelemetry is stateless, so migration is straightforward.

#### Update Configuration

**Update `values.yaml` exporter endpoints**:

```yaml
# Before (cross-namespace):
defaultCRConfig:
  config:
    exporters:
      prometheusremotewrite:
        endpoint: "http://kube-prometheus-stack-prometheus.prometheus.svc.cluster.local:9090/api/v1/write"

      otlp/tempo:
        endpoint: "tempo.grafana.svc.cluster.local:4317"

      otlphttp/loki:
        endpoint: "http://loki-gateway.grafana.svc.cluster.local/otlp"

# After (same namespace):
defaultCRConfig:
  config:
    exporters:
      prometheusremotewrite:
        endpoint: "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"

      otlp/tempo:
        endpoint: "tempo.monitoring.svc.cluster.local:4317"

      otlphttp/loki:
        endpoint: "http://loki-gateway.monitoring.svc.cluster.local/otlp"
```

**Update namespace override**:

```yaml
# Add to values.yaml
namespaceOverride: "monitoring"
```

#### Uninstall Old OpenTelemetry

```bash
# Uninstall from opentelemetry namespace
helm -n opentelemetry uninstall opentelemetry-kube-stack

# Wait for pods to terminate
kubectl -n opentelemetry get pods --watch

# Optional: Clean up custom resources
kubectl -n opentelemetry delete opentelemetrycollector --all

# Optional: Delete the old namespace
kubectl delete namespace opentelemetry
```

#### Install New OpenTelemetry

```bash
# Install to monitoring namespace
bin/install-opentelemetry-kube-stack.sh

# Verify installation
kubectl -n monitoring get pods -l app.kubernetes.io/name=opentelemetry-collector

# Check collector logs
kubectl -n monitoring logs deployment/opentelemetry-kube-stack-deployment-collector --tail=50
kubectl -n monitoring logs daemonset/opentelemetry-kube-stack-daemon-collector --tail=50

# Verify exporters are working (should see successful connections)
kubectl -n monitoring logs deployment/opentelemetry-kube-stack-deployment-collector | grep -i "exporter"
```

**Expected Output**:
```
INFO    exporters/prometheusremotewrite Successfully sent metrics
INFO    exporters/otlp Connected to tempo
INFO    exporters/otlphttp Connected to loki
```

---

### Phase 2: Migrate Loki

⚠️ **Warning**: This will delete all historical logs stored in Loki!

#### Uninstall Old Loki

```bash
# Uninstall Loki from grafana namespace
helm -n grafana uninstall loki

# Wait for pods to terminate
kubectl -n grafana get pods -l app.kubernetes.io/name=loki --watch
```

#### Delete Old PVCs

PVCs cannot be moved across namespaces and must be deleted:

```bash
# List Loki PVCs
kubectl -n grafana get pvc | grep loki

# Example output:
# NAME                         STATUS   VOLUME                                     CAPACITY   ACCESS MODES
# data-loki-write-0            Bound    pvc-abc123                                 10Gi       RWO
# data-loki-write-1            Bound    pvc-def456                                 10Gi       RWO
# data-loki-backend-0          Bound    pvc-ghi789                                 10Gi       RWO
```

**Option 1: Delete via kubectl**

```bash
# Delete Loki write PVCs
kubectl -n grafana delete pvc data-loki-write-0
kubectl -n grafana delete pvc data-loki-write-1
kubectl -n grafana delete pvc data-loki-write-2  # If exists

# Delete Loki backend PVCs
kubectl -n grafana delete pvc data-loki-backend-0
kubectl -n grafana delete pvc data-loki-backend-1  # If exists

# Delete Loki read PVCs (if using read component)
kubectl -n grafana delete pvc data-loki-read-0  # If exists
```

**Option 2: Delete via k9s** (Recommended)

```bash
# Launch k9s
k9s

# Navigate:
# 1. Type :pvc to view PersistentVolumeClaims
# 2. Type /loki to filter Loki PVCs
# 3. Navigate to each PVC with arrow keys
# 4. Press 'ctrl+d' to delete
# 5. Confirm deletion
```

**Verify PVCs are deleted**:

```bash
kubectl -n grafana get pvc | grep loki
# Should return: No resources found
```

#### Install New Loki

```bash
# Install Loki to monitoring namespace
bin/install-loki.sh

# Verify installation
kubectl -n monitoring get pods -l app.kubernetes.io/name=loki

# Check if Loki is ready
kubectl -n monitoring wait --for=condition=ready pod -l app.kubernetes.io/name=loki --timeout=300s

# Verify PVCs are created
kubectl -n monitoring get pvc | grep loki

# Test Loki is accepting logs
kubectl -n monitoring port-forward svc/loki-gateway 3100:80 &
curl http://localhost:3100/ready
# Expected: ready
```

---

### Phase 3: Migrate Prometheus

⚠️ **Warning**: This will delete all historical metrics stored in Prometheus!

#### Uninstall Old Prometheus

```bash
# Uninstall Prometheus from prometheus namespace
helm -n prometheus uninstall kube-prometheus-stack

# Wait for all pods to terminate
kubectl -n prometheus get pods --watch

# Verify StatefulSets are gone
kubectl -n prometheus get statefulset
```

#### Delete Old PVCs

```bash
# List Prometheus PVCs
kubectl -n prometheus get pvc

# Example output:
# NAME                                                       STATUS   VOLUME
# prometheus-kube-prometheus-stack-prometheus-db-0           Bound    pvc-xyz123
# alertmanager-kube-prometheus-stack-alertmanager-db-0       Bound    pvc-abc456
```

**Delete Prometheus PVCs**:

```bash
# Delete Prometheus data PVCs
kubectl -n prometheus delete pvc prometheus-kube-prometheus-stack-prometheus-db-0

# Delete Alertmanager PVCs
kubectl -n prometheus delete pvc alertmanager-kube-prometheus-stack-alertmanager-db-0
```

**Using k9s**:

```bash
k9s
# Navigate to :pvc
# Delete prometheus and alertmanager PVCs
```

**Verify deletion**:

```bash
kubectl -n prometheus get pvc
# Should return: No resources found
```

#### Update Prometheus Configuration

**Update `values.yaml` for kube-prometheus-stack**:

```yaml
# Update namespace-specific settings
namespaceOverride: monitoring

# Update service monitors to work in new namespace
prometheus:
  prometheusSpec:
    # Service monitor selectors
    serviceMonitorNamespaceSelector:
      matchNames:
        - monitoring
        - kube-system
        - openstack  # If monitoring OpenStack services

    # Pod monitor selectors
    podMonitorNamespaceSelector:
      matchNames:
        - monitoring
        - kube-system

    # External labels
    externalLabels:
      cluster: openstack-genestack
```

#### Install New Prometheus

```bash
# Install Prometheus to monitoring namespace
bin/install-kube-prometheus-stack.sh

# Verify installation
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus

# Wait for Prometheus to be ready
kubectl -n monitoring wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus --timeout=300s

# Check Prometheus is scraping targets
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &

# Open browser to http://localhost:9090/targets
# Verify targets are being scraped
```

**Verify Prometheus is receiving metrics from OTel**:

```bash
# Port-forward to Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &

# Query for OTel metrics
curl -s 'http://localhost:9090/api/v1/query?query=up{job="opentelemetry-deployment"}' | jq '.data.result'

# Should see metrics from OTel collectors
```

---

### Phase 4: Migrate Grafana

⚠️ **Warning**: This will delete Grafana dashboards, datasources, and database!

#### Export Dashboards (Optional)

If you want to preserve dashboards:

```bash
# Create export directory
mkdir -p grafana-dashboards-export

# Get list of dashboards
kubectl -n grafana get configmap -l grafana_dashboard=1 -o name

# Export each dashboard
for cm in $(kubectl -n grafana get configmap -l grafana_dashboard=1 -o name); do
  kubectl -n grafana get $cm -o yaml > grafana-dashboards-export/${cm}.yaml
done

# Verify exports
ls -la grafana-dashboards-export/
```

#### Uninstall Old Grafana

```bash
# Uninstall Grafana from grafana namespace
helm -n grafana uninstall grafana

# Wait for pods to terminate
kubectl -n grafana get pods -l app.kubernetes.io/name=grafana --watch
```

#### Delete Old Database

Grafana uses MariaDB for storing dashboards, datasources, and users.

**Delete Grafana MariaDB resources**:

```bash
# Delete the MariaDB StatefulSet
kubectl -n grafana delete statefulset mariadb-cluster

# List Grafana database PVCs
kubectl -n grafana get pvc | grep grafana

# Delete Grafana MariaDB PVCs
kubectl -n grafana delete pvc storage-mariadb-cluster-0

# If using k9s for easier cleanup
# k9s → :pvc → /grafana → delete each PVC
```

**Manual cleanup** (if needed):

```bash
# Delete leftover MariaDB pods
kubectl -n grafana delete pods -l app.kubernetes.io/name=mariadb,app.kubernetes.io/instance=grafana

# Delete leftover services
kubectl -n grafana delete svc grafana
kubectl -n grafana delete svc grafanas

# Delete leftover secrets
kubectl -n grafana delete secret grafana-db

# Delete leftover ConfigMaps
kubectl -n grafana delete configmap grafana-mariadb
```

#### Update Grafana Configuration

**Update `values.yaml` for Grafana**:

```yaml
# Update datasource URLs to point to monitoring namespace
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
        isDefault: true

      - name: Loki
        type: loki
        url: http://loki-gateway.monitoring.svc.cluster.local

      - name: Tempo
        type: tempo
        url: http://tempo.monitoring.svc.cluster.local:3100
```

#### Install New Grafana

```bash
# Install Grafana to monitoring namespace
bin/install-grafana.sh

# Verify installation
kubectl -n monitoring get pods -l app.kubernetes.io/name=grafana

# Wait for Grafana to be ready
kubectl -n monitoring wait --for=condition=ready pod -l app.kubernetes.io/name=grafana --timeout=300s
```

#### Create Grafana Database

```bash
# Apply the database manifest
kubectl apply -f base-kustomize/grafana/base/grafana-database.yaml

# Wait for database to be ready
kubectl -n monitoring wait --for=condition=ready pod -l application=grafana-postgres --timeout=300s

# Verify database
kubectl -n monitoring get postgresql grafana-postgres
```

#### Restore Dashboards

**Option 1: Re-import via Helm/Kustomize**

If your dashboards are defined in Helm values or Kustomize:

```bash
# Re-apply dashboard ConfigMaps
kubectl apply -k base-kustomize/grafana/dashboards/

# Grafana will auto-import them
```

**Option 2: Import via UI**

```bash
# Port-forward to Grafana
kubectl -n monitoring port-forward svc/grafana 3000:80

# Open browser to http://localhost:3000
# Login with admin credentials
# Navigate to Dashboards → Import
# Upload exported dashboard JSON files
```

**Option 3: Import via Script**

```bash
# Use the Genestack import script
python3 scripts/import-grafana-dashboard.py \
  --grafana-url http://localhost:3000 \
  --api-key <your-api-key> \
  --dashboard-dir grafana-dashboards-export/

# Or import from Grafana.com
python3 scripts/import-grafana-dashboard.py \
  --grafana-url http://localhost:3000 \
  --api-key <your-api-key> \
  --dashboard-id 7249  # Example: Kubernetes cluster monitoring
```

---

### Phase 5: Update Cross-References

#### Update ServiceMonitors

If you have custom ServiceMonitors, update their namespace references:

```bash
# Find ServiceMonitors referencing old namespaces
kubectl get servicemonitor -A -o yaml | grep -E "namespace: (prometheus|grafana|opentelemetry)"

# Update each ServiceMonitor
kubectl get servicemonitor <name> -n <namespace> -o yaml \
  | sed 's/namespace: prometheus/namespace: monitoring/g' \
  | sed 's/namespace: grafana/namespace: monitoring/g' \
  | sed 's/namespace: opentelemetry/namespace: monitoring/g' \
  | kubectl apply -f -
```

#### Update Ingresses

If you have Ingress resources:

```bash
# Update Prometheus Ingress
kubectl get ingress prometheus -n prometheus -o yaml \
  | sed 's/namespace: prometheus/namespace: monitoring/g' \
  | kubectl apply -f -

# Update Grafana Ingress
kubectl get ingress grafana -n grafana -o yaml \
  | sed 's/namespace: grafana/namespace: monitoring/g' \
  | kubectl apply -f -
```

#### Update NetworkPolicies

```bash
# Update NetworkPolicies to allow traffic within monitoring namespace
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring-internal
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: monitoring
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              name: monitoring
EOF
```

---

## Post-Migration Verification

### Verification Checklist

Run through this checklist to ensure everything is working:

#### 1. Check All Pods Running

```bash
# All monitoring pods should be running
kubectl -n monitoring get pods

# Expected pods:
# - opentelemetry-kube-stack-daemon-collector-*
# - opentelemetry-kube-stack-deployment-collector-*
# - prometheus-kube-prometheus-stack-prometheus-0
# - alertmanager-kube-prometheus-stack-alertmanager-0
# - loki-write-*
# - loki-read-*
# - loki-backend-*
# - tempo-*
# - grafana-*
```

#### 2. Verify Metrics Flow

```bash
# Port-forward to Prometheus
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &

# Query for metrics from OTel
curl -s 'http://localhost:9090/api/v1/query?query=up{job="opentelemetry-deployment"}' | jq '.data.result[0].value'

# Should return: ["timestamp", "1"]

# Check database metrics
curl -s 'http://localhost:9090/api/v1/query?query=mysql_connection_count' | jq '.data.result'

# Should see MySQL metrics

# Check RabbitMQ metrics
curl -s 'http://localhost:9090/api/v1/query?query=rabbitmq_message_current' | jq '.data.result'

# Should see RabbitMQ metrics with labels
```

#### 3. Verify Logs Flow

```bash
# Port-forward to Loki
kubectl -n monitoring port-forward svc/loki-gateway 3100:80 &

# Query for recent logs
curl -s 'http://localhost:3100/loki/api/v1/query?query={namespace="openstack"}&limit=10' | jq '.data.result'

# Should see log entries from OpenStack namespace

# Query for Kubernetes logs
curl -s 'http://localhost:3100/loki/api/v1/query?query={namespace="kube-system"}&limit=10' | jq '.data.result'

# Should see log entries
```

#### 4. Verify Traces Flow

```bash
# Port-forward to Tempo
kubectl -n monitoring port-forward svc/tempo 3100:3100 &

# Check Tempo readiness
curl http://localhost:3100/ready

# Expected: ready

# Query for recent traces (requires traces to exist)
curl -s 'http://localhost:3100/api/search' | jq '.'
```

#### 5. Verify Grafana

```bash
# Port-forward to Grafana
kubectl -n monitoring port-forward svc/grafana 3000:80 &

# Open browser to http://localhost:3000

# Login with admin credentials

# Verify datasources:
# 1. Go to Configuration → Data Sources
# 2. Test Prometheus connection
# 3. Test Loki connection
# 4. Test Tempo connection

# Verify dashboards are visible and loading data
```

#### 6. Check for Errors

```bash
# Check OTel collector logs for errors
kubectl -n monitoring logs deployment/opentelemetry-kube-stack-deployment-collector --tail=100 | grep -i error

# Check Prometheus logs
kubectl -n monitoring logs prometheus-kube-prometheus-stack-prometheus-0 --tail=100 | grep -i error

# Check Loki logs
kubectl -n monitoring logs deployment/loki-write --tail=100 | grep -i error

# Check Grafana logs
kubectl -n monitoring logs deployment/grafana --tail=100 | grep -i error
```

#### 7. Verify Service Discovery

```bash
# Prometheus should discover OTel ServiceMonitors
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &

# Open http://localhost:9090/targets
# Should see:
# - serviceMonitor/monitoring/opentelemetry-kube-stack-daemon-collector-monitoring/0
# - serviceMonitor/monitoring/opentelemetry-kube-stack-deployment-collector-monitoring/0
```

#### 8. Test End-to-End Flow

```bash
# Generate a test log entry
kubectl -n openstack run test-pod --image=busybox --restart=Never -- sh -c "echo 'Test log from migration verification' && sleep 10"

# Wait 30 seconds for log ingestion

# Query Loki for the test log
curl -s 'http://localhost:3100/loki/api/v1/query?query={pod="test-pod"}&limit=10' | jq '.data.result'

# Should see the test log entry

# Cleanup
kubectl -n openstack delete pod test-pod
```

### Expected Metrics After Migration

You should see these metric families in Prometheus:

```promql
# OpenTelemetry metrics
up{job="opentelemetry-deployment"}
up{job="opentelemetry-daemon"}

# Database metrics
mysql_connection_count
postgresql_backends
rabbitmq_message_current
memcached_operation_hit_ratio

# Kubernetes metrics (from ServiceMonitors)
kubelet_*
kube_pod_*
node_*
container_*

# Loki metrics (from Loki itself)
loki_ingester_*
loki_distributor_*

# Prometheus metrics (from Prometheus itself)
prometheus_tsdb_*
prometheus_http_*
```

---

## Rollback Procedure

If something goes wrong, follow this rollback procedure:

### Quick Rollback (Return to Old Namespaces)

```bash
# 1. Uninstall from monitoring namespace
helm -n monitoring uninstall opentelemetry-kube-stack
helm -n monitoring uninstall kube-prometheus-stack
helm -n monitoring uninstall loki
helm -n monitoring uninstall grafana

# 2. Delete monitoring namespace
kubectl delete namespace monitoring

# 3. Restore from backups
cd monitoring-migration-backup/

# 4. Reinstall to original namespaces
bin/install-opentelemetry-kube-stack.sh  # Uses default namespace
bin/install-kube-prometheus-stack.sh     # Uses default namespace
bin/install-loki.sh                      # Uses default namespace
bin/install-grafana.sh                   # Uses default namespace

# 5. Restore Prometheus values
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n prometheus \
  -f prometheus-values-backup.yaml

# 6. Restore OTel values
helm upgrade opentelemetry-kube-stack open-telemetry/opentelemetry-operator \
  -n opentelemetry \
  -f otel-values-backup.yaml
```

### Partial Rollback (One Component)

If only one component failed:

**Rollback OpenTelemetry only**:

```bash
helm -n monitoring uninstall opentelemetry-kube-stack
bin/install-opentelemetry-kube-stack.sh  # Installs to opentelemetry namespace
```

**Rollback Prometheus only**:

```bash
helm -n monitoring uninstall kube-prometheus-stack
kubectl -n monitoring delete pvc -l app.kubernetes.io/name=prometheus
bin/install-kube-prometheus-stack.sh  # Installs to prometheus namespace
```

---

## Troubleshooting

### Common Issues and Solutions

#### Issue 1: Pods Not Starting in Monitoring Namespace

**Symptoms**:
```bash
kubectl -n monitoring get pods
# Shows pods in CrashLoopBackOff or Pending state
```

**Diagnosis**:
```bash
# Check pod events
kubectl -n monitoring describe pod <pod-name>

# Check pod logs
kubectl -n monitoring logs <pod-name>
```

**Common Causes**:
- Missing secrets → Verify secrets were copied
- Insufficient resources → Check node capacity
- Storage issues → Verify PVCs are bound

**Solution**:
```bash
# Verify secrets exist
kubectl -n monitoring get secrets

# Check resource quotas
kubectl -n monitoring get resourcequota

# Check PVC status
kubectl -n monitoring get pvc
```

#### Issue 2: Metrics Not Flowing to Prometheus

**Symptoms**:
- Prometheus UI shows no targets or targets are down
- No metrics from OpenTelemetry collectors

**Diagnosis**:
```bash
# Check Prometheus targets
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# Open http://localhost:9090/targets

# Check OTel exporter logs
kubectl -n monitoring logs deployment/opentelemetry-kube-stack-deployment-collector | grep prometheusremotewrite
```

**Common Causes**:
- Wrong endpoint URL in OTel config
- Network policy blocking traffic
- ServiceMonitor not discovered

**Solution**:
```bash
# Verify OTel config has correct endpoint
kubectl -n monitoring get opentelemetrycollector opentelemetry-kube-stack-deployment -o yaml | grep prometheusremotewrite -A 5

# Should show:
#   endpoint: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write

# Test connectivity from OTel pod to Prometheus
kubectl -n monitoring exec deployment/opentelemetry-kube-stack-deployment-collector -- \
  wget -O- http://kube-prometheus-stack-prometheus:9090/-/healthy

# Expected: Prometheus is Healthy
```

#### Issue 3: Logs Not Appearing in Loki

**Symptoms**:
- Grafana shows "No logs found"
- Loki queries return empty results

**Diagnosis**:
```bash
# Check Loki readiness
kubectl -n monitoring port-forward svc/loki-gateway 3100:80 &
curl http://localhost:3100/ready

# Check OTel logs for Loki errors
kubectl -n monitoring logs daemonset/opentelemetry-kube-stack-daemon-collector | grep loki

# Check Loki ingester logs
kubectl -n monitoring logs deployment/loki-write | grep -i error
```

**Common Causes**:
- Incorrect Loki endpoint in OTel config
- Loki not ready (still starting)
- Labels missing on logs

**Solution**:
```bash
# Verify OTel Loki endpoint
kubectl -n monitoring get opentelemetrycollector opentelemetry-kube-stack-daemon -o yaml | grep loki -A 3

# Should show:
#   endpoint: http://loki-gateway.monitoring.svc.cluster.local/otlp

# Test Loki endpoint from OTel pod
kubectl -n monitoring exec daemonset/opentelemetry-kube-stack-daemon-collector -- \
  wget -O- http://loki-gateway/ready
```

#### Issue 4: Grafana Can't Connect to Datasources

**Symptoms**:
- Datasource test fails in Grafana UI
- Dashboards show "No data"

**Diagnosis**:
```bash
# Check Grafana logs
kubectl -n monitoring logs deployment/grafana | grep -i datasource

# Port-forward and test datasources manually
kubectl -n monitoring port-forward svc/grafana 3000:80 &
# Go to http://localhost:3000/datasources
# Click "Test" on each datasource
```

**Solution**:
```bash
# Update datasource URLs in Grafana values
# URLs should be:
# Prometheus: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090
# Loki:       http://loki-gateway.monitoring.svc.cluster.local
# Tempo:      http://tempo.monitoring.svc.cluster.local:3100

# Upgrade Grafana with corrected values
helm upgrade grafana grafana/grafana -n monitoring -f values-grafana.yaml
```

#### Issue 5: Database Metrics Not Appearing

**Symptoms**:
- No `mysql_*`, `postgresql_*`, or `rabbitmq_*` metrics in Prometheus

**Diagnosis**:
```bash
# Check deployment collector logs
kubectl -n monitoring logs deployment/opentelemetry-kube-stack-deployment-collector | grep -E "mysql|postgresql|rabbitmq"

# Check if secrets exist
kubectl -n monitoring get secret mariadb-monitoring
kubectl -n monitoring get secret postgres.postgres-cluster.credentials.postgresql.acid.zalan.do
kubectl -n monitoring get secret rabbitmq-default-user
```

**Common Causes**:
- Secrets not copied to monitoring namespace
- Wrong secret names in deployment collector config
- Database endpoints unreachable

**Solution**:
```bash
# Re-copy secrets (see Phase 0)
kubectl -n openstack get secret mariadb-monitoring -o yaml \
  | sed 's/namespace: openstack/namespace: monitoring/' \
  | kubectl apply -f -

# Restart deployment collector to pick up secrets
kubectl -n monitoring rollout restart deployment/opentelemetry-kube-stack-deployment-collector

# Verify metrics start appearing
kubectl -n monitoring logs deployment/opentelemetry-kube-stack-deployment-collector --tail=50 | grep "Successfully"
```

#### Issue 6: "Out of Order" Errors in Prometheus

**Symptoms**:
```bash
kubectl -n monitoring logs prometheus-kube-prometheus-stack-prometheus-0 | grep "out of order"
```

**Cause**:
- Duplicate metrics from multiple sources
- `target_info` metric with dynamic labels

**Solution**:
```bash
# See main documentation for full fix
# Quick fix: Disable target_info in OTel exporters

# Update values.yaml:
exporters:
  prometheusremotewrite:
    target_info:
      enabled: false
```

---

## Post-Migration Cleanup

After verifying everything works, clean up old namespaces:

```bash
# Delete old namespaces (only if everything is working!)
kubectl delete namespace opentelemetry
kubectl delete namespace prometheus
kubectl delete namespace grafana

# Clean up backup directory
rm -rf monitoring-migration-backup/

# Clean up port-forwards
pkill -f "kubectl port-forward"
```

---

## Summary

### Migration Checklist

- [ ] Phase 0: Create monitoring namespace and copy secrets
- [ ] Phase 1: Migrate OpenTelemetry (stateless, quick)
- [ ] Phase 2: Migrate Loki (deletes historical logs)
- [ ] Phase 3: Migrate Prometheus (deletes historical metrics)
- [ ] Phase 4: Migrate Grafana (deletes dashboards/datasources)
- [ ] Phase 5: Update cross-references (ServiceMonitors, Ingresses)
- [ ] Verification: All components working in monitoring namespace
- [ ] Cleanup: Delete old namespaces

### Migration Duration

Total expected time: **30-45 minutes**

- Preparation: 5 minutes
- OpenTelemetry: 5 minutes
- Loki: 10 minutes
- Prometheus: 10 minutes
- Grafana: 10 minutes
- Verification: 5 minutes

### Key Takeaways

✅ **Benefits**:
- Simplified namespace management
- Easier service discovery
- Better RBAC organization
- Cleaner endpoint URLs

⚠️ **Trade-offs**:
- Loss of historical data (metrics, logs, traces)
- Downtime during migration
- Need to re-import dashboards

📋 **Best Practices**:
- Schedule during maintenance window
- Export important dashboards beforehand
- Test in dev/staging first
- Keep backups of all configurations
- Verify each phase before proceeding

---

## Additional Resources

- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [Prometheus Operator Guide](https://prometheus-operator.dev/)
- [Loki Documentation](https://grafana.com/docs/loki/)
- [Grafana Documentation](https://grafana.com/docs/grafana/)
- [Genestack Monitoring Setup](https://github.com/rackerlabs/genestack)

---

**Document Version**: 1.0
**Last Updated**: 2026-03-17
**Tested On**: Kubernetes 1.28+, Helm 3.12+
