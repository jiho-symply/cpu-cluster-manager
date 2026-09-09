# Dual-OS deployment

This repository supports the same service contract on both clusters:

- Cluster 1: Ubuntu 20.04
- Cluster 2: CentOS 7
- Administrative SSH user: existing `ysadmin`
- Control plane: FastAPI over a dedicated restricted SSH key
- Monitoring: native `node_exporter` on each compute node, Prometheus + Grafana on each master
- Recent history: 30-second samples for 30 days
- Long-term history: 5-minute buckets with min/avg/max, maximum 5 years
- Long-term archive block budget: 80MB per compute node
- Alerts: disk-capacity alerts only

## Why monitoring is native on compute nodes

The compute-node monitoring path intentionally does not run cAdvisor in Docker. RHEL/CentOS 7 requires extra privileged/cgroup mounts for containerized cAdvisor, while Ubuntu 20.04 differs in cgroup layout. Because this project only needs metrics for one managed container (`rent-node`), a native `node_exporter` plus its textfile collector is simpler and more portable.

Every 30 seconds a systemd timer runs `docker stats --no-stream rent-node` and writes four gauges into the node_exporter textfile directory:

- `cluster_rent_container_running`
- `cluster_rent_container_cpu_percent`
- `cluster_rent_container_memory_usage_bytes`
- `cluster_rent_container_memory_limit_bytes`

Prometheus combines those gauges with normal node_exporter host metrics. Only TCP/9100 is required from master to compute nodes.

## Long-term archive contract

Hot Prometheus creates one aggregate sample every 5 minutes. For each bucket it preserves min/avg/max for:

- host CPU utilization;
- host memory utilization;
- the most-used real filesystem utilization;
- `rent-node` CPU cores;
- `rent-node` memory usage;
- `rent-node` running ratio.

That is 18 archive series per compute node. Archive Prometheus federates only metric names matching `archive_*5m` every 5 minutes.

Retention uses both:

- maximum time: 5 years;
- maximum persistent-block size: 80MB × compute-node count.

Whichever condition is reached first removes older blocks. The size budget deliberately leaves headroom below the operational target of 100MB per compute node. Prometheus `retention.size` applies to persistent blocks; WAL/head and temporary compaction overlap are shared Archive-Prometheus overhead and are not a strict per-node hard limit.

No historical TSDB is stored on compute nodes themselves. Compute nodes store only node_exporter, the collector script, and the small current textfile metric.

## Master contract

Both master OS variants use the same repository and `docker-compose.yml`. The project does not automatically install or upgrade Docker on either OS. `scripts/preflight.sh master` validates the existing environment and `scripts/compose.sh` supports either:

- `docker compose` (Compose plugin), or
- `docker-compose` (legacy standalone command).

This matters because CentOS 7 installations often use an older Docker/Compose stack.

## Compute-node contract

`node/install-node.sh` performs the same logical steps on both operating systems:

1. validates the host with `scripts/preflight.sh compute`;
2. keeps the existing `ysadmin` account;
3. installs the restricted Cluster Manager public key without replacing human/admin keys;
4. installs `cluster-node-admin` and its forced-command SSH dispatcher;
5. installs native node_exporter and the `rent-node` textfile collector as systemd services/timer;
6. verifies that `http://127.0.0.1:9100/metrics` is healthy.

No new management Linux account is created.

## Inventory

The deployed `config/nodes.yaml` is local-only and is not committed.

Cluster 1 example:

```yaml
cluster: cluster1
platform: ubuntu20
ssh_user: ysadmin
nodes:
  - name: cpu-01
    host: <IP>
    port: 22
```

Cluster 2 example:

```yaml
cluster: cluster2
platform: centos7
ssh_user: ysadmin
nodes:
  - name: cpu-07
    host: <IP>
    port: 22
```

The target renderer adds `cluster`, `platform`, and `node` labels to every Prometheus target so the same dashboards and recording rules work for both clusters.

## Deployment order

On each cluster master:

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
cp config/nodes.example.yaml config/nodes.yaml        # Cluster 1
# or copy config/nodes.cluster2.example.yaml           # Cluster 2
# edit config/nodes.yaml with real addresses
cp .env.example .env
# set ADMIN_PASSWORD
./scripts/install-master.sh config/nodes.yaml
```

`install-master.sh` counts the compute nodes and sets `ARCHIVE_RETENTION_SIZE` to `80MB × node count` before starting the stack.

Then, for every compute node, copy only the generated public key from that cluster's master and run:

```bash
sudo ./node/install-node.sh /tmp/cluster-manager_ed25519.pub
```

## Network policy

Master -> compute node:

- TCP/22: Cluster Manager control SSH
- TCP/9100: Prometheus scraping

Compute node monitoring should not expose TCP/9100 outside the corresponding cluster master/network policy.

FastAPI and Grafana bind to `127.0.0.1` on the master by default and should normally be reached through an administrator SSH tunnel.

## OS-specific caveats

### Ubuntu 20.04

Ubuntu 20.04 is outside Docker's current package-support list. This project therefore treats the already-installed Docker Engine as infrastructure and does not replace it during application installation.

### CentOS 7

CentOS 7 is EOL and current Docker CE packages no longer support it. Existing Docker installations can continue to be used if they pass preflight and runtime checks. The preflight also warns about very old RHEL/CentOS 7 kernels because Docker stability is more sensitive there.

If either cluster later receives an OS upgrade, the monitoring/control contract does not change; only preflight/platform handling needs to be extended.
