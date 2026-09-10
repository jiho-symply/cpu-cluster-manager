# Dual-OS deployment notes

## Validated hosts

- Cluster 1: Ubuntu 20.04.2, kernel 5.15, Docker 20.10.x, Compose 2.6.0
- Cluster 2: CentOS 7, kernel 3.10.0-1160, Docker 20.10.17, Compose 2.6.0
- Host admin account: existing `ysadmin`
- Rent environment: Ubuntu 22.04 `rent-node`

Prometheus 3.14.0, Alertmanager 0.34.0, Grafana 13.2.1 and Python 3.12 Bookworm images were smoke-tested on both masters. Ubuntu 22.04 container execution and `:Z` bind mounts were smoke-tested on representative compute nodes.

## Storage topology

The actual clusters use shared filesystems:

- Cluster 1 master: `/home` local ext4; compute nodes mount the master `/home` through NFS.
- Cluster 2 master: `/home` local 30 TB XFS and `/opt` on the root XFS; compute nodes mount **both `/home` and `/opt` from the master through NFSv3**.
- On both compute families, `/var/lib`, `/etc`, `/usr/local` and `/src/rent` are host-local.

Therefore `/home` and `/opt` must not hold master-only secrets. Master config, manager SSH state and deploy metadata live under:

```text
/var/lib/cpu-cluster-manager
```

The installer checks that this path is not NFS/CIFS before storing secrets.

The Git checkout intentionally remains under the shared `/home` and contains no secrets. It is the cluster-wide deployment source:

```text
/home/ysadmin/cpu-cluster-manager
```

The master writes two generated, Git-ignored, non-secret files there:

```text
.cluster-source-state    commit/tree/source-hash stamp
.cluster-manager.pub     manager PUBLIC key only
```

Compute installers recompute the source SHA256 before deployment, so compute hosts do not need Git installed or a separate repository clone.

## Private management networks

```text
Cluster 1: 192.168.100.x
Cluster 2: 172.20.x.x
```

Master→representative-compute ICMP and TCP/22 were validated on these paths. Prometheus uses the same private IPs for TCP/9100.

Renter account naming remains based on the default-route/public IPv4 last octet and is independent of the management address.

## Single operator-managed file

Each master has exactly one manually managed local config/secret file:

```text
/var/lib/cpu-cluster-manager/cluster.local.env
```

```dotenv
CLUSTER=cluster1
NODES=kfai-cpu-01@192.168.100.11,...
ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=<generated>
UI_PORT=8080
GRAFANA_PORT=3000
```

No `.env`, `nodes.yaml`, or hand-written Prometheus target JSON is required.

Master-only SSH state is also host-local:

```text
/var/lib/cpu-cluster-manager/ssh/id_ed25519
/var/lib/cpu-cluster-manager/ssh/id_ed25519.pub
/var/lib/cpu-cluster-manager/ssh/known_hosts
```

## Master install

```bash
git clone --branch dual-os-support --single-branch \
  https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
bash scripts/install-master.sh
```

A fresh master may prompt for sudo once to create the host-local state directory. First run creates the onefile and exits. Edit only `NODES=`:

```bash
vim /var/lib/cpu-cluster-manager/cluster.local.env
bash scripts/install-master.sh
```

If `ADMIN_PASSWORD` is blank, a random password is written to the same mode-600 file.

Legacy pilot state under shared `/home` is migrated automatically. Existing manager key material is copied to host-local storage to preserve compute authorization; shared-home private-key copies are removed only after the new master stack is healthy.

The installer does not replace Docker Engine or modify site firewall/iptables policy. A successful install requires FastAPI/Grafana health checks and stable restart counts for all six master containers.

## Compute install

The compute consumes the master's shared source checkout. No compute-side Git clone, Git installation, `scp`, `.env`, JSON or key-file copying is needed.

On each compute:

```bash
cd /home/ysadmin/cpu-cluster-manager
sudo bash node/install-node.sh
```

The installer reads the shared `.cluster-manager.pub`, validates `.cluster-source-state`, recomputes the source SHA256, and then deploys host-local management/runtime files.

The compute installer manages:

- `/src/rent/image`
- `/usr/local/sbin/cluster-node-admin`
- `/usr/local/bin/cluster-node-ssh`
- `/usr/local/bin/rent-node-metrics`
- `/etc/sudoers.d/cpu-cluster-manager`
- monitoring systemd units
- `/var/lib/cpu-cluster-manager/manager.pub`
- `/var/lib/cpu-cluster-manager/deployed-version`

Persistent `/src/rent/home`, `/src/rent/work`, `/src/rent/auth`, `/src/rent/ssh` are never treated as Git content.

Cluster 1 pilot validation confirmed an existing `rent-node` kept the same container ID, start timestamp, image ID, renter UID and persistent-directory inodes after installation.

## Updates

Run Git only on the master:

```bash
cd /home/ysadmin/cpu-cluster-manager
bash scripts/update-master.sh
```

Then on each compute:

```bash
cd /home/ysadmin/cpu-cluster-manager
bash node/update-node.sh
```

Compute update does not invoke Git. It validates the shared source stamp/hash and redeploys local management files. The stored `/var/lib/cpu-cluster-manager/manager.pub` may be passed back to the installer safely; this path is explicitly idempotent.

## Verification

Compute:

```bash
bash node/verify-node.sh
```

Whole cluster from master:

```bash
bash scripts/verify-cluster.sh
```

Deployment metadata on both roles:

```bash
cat /var/lib/cpu-cluster-manager/deployed-version
```

## Shared `authorized_keys`

Both validated clusters share `/home`, so `ysadmin`'s normal `~/.ssh/authorized_keys` is also shared by the existing infrastructure. The compute installer adds only a forced-command/no-forwarding entry containing the manager public key. The manager private key is never placed under shared `/home`; it remains master-local under `/var/lib/cpu-cluster-manager/ssh`.

## Monitoring contract

Compute node:

- native node_exporter v1.12.1
- release SHA256 verification
- source-controlled systemd unit
- 30-second source-controlled timer collecting `docker stats rent-node`
- TCP/9100 on private management network

Master:

- Dockerized node_exporter on the internal Compose network
- Prometheus Hot: 30s / 30d
- Prometheus Archive: 5m min/avg/max / max 5y
- Grafana automatic `$__interval`
- disk-capacity alerts only

Archive compute cardinality is 18 series per compute node. Persistent block budget is 32 MB per monitored host (master + compute). Archive WAL segment size is 10 MB, the minimum accepted by the deployed Prometheus 3.14 image. CI performs a real Prometheus startup test for these storage flags.

The block budget does not hard-cap transient Prometheus head/WAL/compaction overhead; actual master disk use should be observed during operation.
