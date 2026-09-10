# Dual-OS deployment notes

## Validated hosts

- Cluster 1: Ubuntu 20.04.2, kernel 5.15, Docker 20.10.x, Compose 2.6.0
- Cluster 2: CentOS 7, kernel 3.10.0-1160, Docker 20.10.17, Compose 2.6.0
- Host admin account: existing `ysadmin`
- Rent environment: Ubuntu 22.04 `rent-node`

Prometheus 3.14.0, Alertmanager 0.34.0, Grafana 13.2.1 and Python 3.12 Bookworm images were smoke-tested on both masters. Ubuntu 22.04 container execution and `:Z` bind mounts were smoke-tested on representative compute nodes.

## Private management networks

Use private management IPs in `cluster.local.env`:

```text
Cluster 1: 192.168.100.x
Cluster 2: 172.20.x.x
```

Master→representative-compute ICMP and TCP/22 were validated on these paths. Prometheus also uses the same private IPs for TCP/9100.

Renter account naming is intentionally independent of this management address. Existing `engclusterXXX` accounts follow the default-route/public service IPv4 last octet, and the rent scripts retain that behavior.

## Single operator-managed file

Each master has exactly one manually managed local config/secret file:

```text
cluster.local.env
```

It contains:

```dotenv
CLUSTER=cluster1
NODES=kfai-cpu-01@192.168.100.11,...
ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=<generated>
UI_PORT=8080
GRAFANA_PORT=3000
```

No `.env`, `nodes.yaml`, or hand-written Prometheus target JSON is required. Generated target JSON is an implementation artifact only.

SSH private keys, known_hosts, renter auth DB, SSH host keys, and Prometheus TSDB are automatically managed runtime state and are not embedded into the env file.

## Master install

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
bash scripts/install-master.sh
```

First run creates `cluster.local.env`, autodetects `cluster1` on the Ubuntu master or `cluster2` on the CentOS master, and exits. Edit `NODES=` with all compute private management IPs, then:

```bash
bash scripts/install-master.sh
```

If `ADMIN_PASSWORD` is blank, a random password is written back to the same mode-600 file.

Master install runs as `ysadmin` without sudo. A successful install requires FastAPI/Grafana health checks and stable state/restart counts for all six master containers.

The installer does not replace Docker Engine or modify site firewall/iptables policy.

## Compute install

Copy only the corresponding master's public key:

```bash
scp ~/.ssh/cluster-manager_ed25519.pub ysadmin@<COMPUTE_PRIVATE_IP>:/tmp/cluster-manager_ed25519.pub
```

Then on the compute node:

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
sudo bash node/install-node.sh /tmp/cluster-manager_ed25519.pub
rm -f /tmp/cluster-manager_ed25519.pub
```

The compute installer treats Git as authoritative for:

- `/src/rent/image` deployed source
- `/usr/local/sbin/cluster-node-admin`
- `/usr/local/bin/cluster-node-ssh`
- `/usr/local/bin/rent-node-metrics`
- `/etc/sudoers.d/cpu-cluster-manager`
- monitoring systemd units

Persistent `/src/rent/home`, `/src/rent/work`, `/src/rent/auth`, `/src/rent/ssh` are never treated as Git content.

Existing `rent-node` is preserved. If `node/rent-image` changed in Git, its tree SHA changes and the Docker image is rebuilt with that SHA as an image label; the running container is not automatically recreated.

## Updates

Master:

```bash
bash scripts/update-master.sh
```

Compute:

```bash
bash node/update-node.sh
```

Both use `git pull --ff-only` and refuse tracked local modifications. There is no Git tag/release workflow; deployed state records the exact commit SHA.

## Verification

Compute:

```bash
bash node/verify-node.sh
```

Whole cluster from master:

```bash
bash scripts/verify-cluster.sh
```

Deployment metadata:

Master:

```bash
cat ~/.local/state/cpu-cluster-manager/deployed-version
```

Compute:

```bash
cat /var/lib/cpu-cluster-manager/deployed-version
```

## Monitoring contract

Compute node:

- native node_exporter v1.12.1
- SHA256 verification
- source-controlled systemd unit
- 30-second source-controlled timer collecting `docker stats rent-node`
- TCP/9100 on private management network

Master:

- Dockerized node_exporter on the internal Compose network
- Prometheus Hot: 30s / 30d
- Prometheus Archive: 5m min/avg/max / max 5y
- Grafana automatic `$__interval`
- disk-capacity alerts only

Archive compute cardinality is 18 series per compute node. Persistent block budget is 32 MB per monitored host (master + compute). Archive WAL segment size is **10 MB**, which is the minimum accepted by Prometheus 3.14. The first Cluster 1 pilot caught and corrected an invalid earlier 8 MB setting; CI now performs an actual Prometheus startup check with the configured storage flags so this class of error is detected before deployment.

The block budget does not hard-cap transient Prometheus head/WAL/compaction overhead. Actual master disk usage should be observed during pilot operation.
