# CPU Cluster Manager

Cluster 1(Ubuntu 20.04)과 Cluster 2(CentOS 7)를 동일한 운영 모델로 관리하는 경량 control/monitoring stack이다.

## Operating model

- **GitHub is the source of truth** for Dockerfile, rent scripts, compute management scripts, sudoers, systemd units, FastAPI, Docker Compose, Prometheus, Grafana, Alertmanager, installers/updaters/verifiers.
- 각 cluster의 master가 `/home/ysadmin/cpu-cluster-manager` Git checkout을 관리한다. 현재 두 cluster 모두 `/home`이 compute에 NFS로 공유되므로 compute는 이 checkout을 **deployment source**로 사용하고 별도 Git clone이나 Git 설치가 필요 없다.
- 운영자가 직접 관리하는 secret/config는 master의 **`/var/lib/cpu-cluster-manager/cluster.local.env` 한 파일뿐**이다.
- master SSH private key, known_hosts, deploy state도 `/var/lib/cpu-cluster-manager`에 저장한다. `/var/lib`은 두 cluster 모두 host-local filesystem이다.
- `/src/rent/image`, `/usr/local/bin`, `/usr/local/sbin`, `/etc/systemd/system`, `/etc/sudoers.d`의 관련 파일은 shared Git source에서 각 compute의 local filesystem으로 설치되는 deployment copy다.
- Git tag/release workflow는 쓰지 않는다. 실제 배포 버전은 Git commit SHA와 source SHA256으로 기록한다.

## Why secrets are not under `/home` or `/opt`

실제 storage topology를 확인한 결과:

- Cluster 1 compute: `/home` = Cluster 1 master의 NFS export
- Cluster 2 compute: `/home` = Cluster 2 master의 NFS export
- Cluster 2 compute: `/opt` 역시 Cluster 2 master의 NFS export
- `/var/lib`, `/etc`, `/usr/local`, compute의 `/src/rent`는 host-local

따라서 master-only secret을 `/home` 또는 `/opt`에 두면 compute에서도 보일 수 있다. 이 프로젝트의 master-only state는 `/var/lib/cpu-cluster-manager`만 사용하며 installer는 해당 경로가 NFS/CIFS이면 중단한다.

## State layout

### Shared source — no secrets

```text
/home/ysadmin/cpu-cluster-manager/
├── .git/
├── .cluster-source-state        generated, non-secret commit/hash stamp
├── .cluster-manager.pub         generated manager PUBLIC key only
├── cluster.local.env.example    template only
├── docker-compose.yml
├── manager/
├── monitoring/
├── node/
└── scripts/
```

`.cluster-source-state` contains the Git commit, branch, remote, rent-image Git tree SHA and a deterministic SHA256 of deployable source files. Compute installers recompute the SHA256 before changing the node; stale or modified shared source is rejected.

`.cluster-manager.pub` is intentionally shared because it is only a public key. The corresponding private key never leaves the master-local `/var/lib/cpu-cluster-manager/ssh` directory.

### Master host-local state

```text
/var/lib/cpu-cluster-manager/
├── cluster.local.env            only operator-managed config/secret, mode 600
├── deployed-version
└── ssh/
    ├── id_ed25519               master-only manager private key
    ├── id_ed25519.pub
    └── known_hosts
```

### Compute host-local state

```text
/var/lib/cpu-cluster-manager/
├── manager.pub
└── deployed-version

/src/rent/
├── image/                       Git-deployed copy; replaceable
├── home/                        persistent renter data
├── work/                        persistent renter data
├── auth/                        persistent auth state
└── ssh/                         persistent rent-node SSH state
```

## One operator-managed file

First master install creates:

```text
/var/lib/cpu-cluster-manager/cluster.local.env
```

with mode 600 and owner `ysadmin`.

```dotenv
CLUSTER=cluster1
NODES=kfai-cpu-01@192.168.100.11,kfai-cpu-02@192.168.100.12
ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=<generated automatically>
UI_PORT=8080
GRAFANA_PORT=3000
```

`NODES` uses private management IPs:

- Cluster 1: `192.168.100.x`
- Cluster 2: `172.20.x.x`

There is no separate `.env`, `nodes.yaml`, or operator-maintained Prometheus target JSON.

## Service contract

- **FastAPI Control Plane (`127.0.0.1:8080`)**: `rent-node` status/renter and Start/Stop/Restart/Recreate/Logs
- **Grafana (`127.0.0.1:3000`)**: host CPU/RAM/disk and `rent-node` CPU/RAM/running history
- **Prometheus Hot**: 30-second scrape, 30-day retention
- **Prometheus Archive**: 5-minute min/avg/max aggregates, up to 5 years
- **Alertmanager**: disk-capacity alerts only
- **Master monitoring**: Dockerized node_exporter on the internal Compose network
- **Compute monitoring**: native node_exporter `:9100` + Git-managed systemd timer/textfile collector
- **Control SSH**: existing `ysadmin` + restricted master-specific key

## Validated infrastructure baseline

- Cluster 1: Ubuntu 20.04.2, kernel 5.15, Docker 20.10.x / API 1.41, Compose 2.6.0
- Cluster 2: CentOS 7, kernel 3.10.0-1160, Docker 20.10.17 / API 1.41, Compose 2.6.0
- Prometheus 3.14.0 / Alertmanager 0.34.0 / Grafana 13.2.1 images execute on both masters
- Ubuntu 22.04 rent container and `:Z` bind mounts execute on both compute OS families
- private master→compute SSH paths validated
- existing `rent-node` preservation validated on Cluster 1 compute: container ID/start time, renter UID and persistent directory inodes remained unchanged after installation

Installer does not replace Docker Engine and does not rewrite site firewall/iptables policy.

## Initial master install

The canonical deployment branch is **`main`**. The former `dual-os-support` branch is retained only for historical reference and is not a deployment target.

```bash
git clone --branch main --single-branch \
  https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
bash scripts/install-master.sh
```

On a fresh master, the first run may request sudo once to create host-local `/var/lib/cpu-cluster-manager`, then creates the onefile and exits. Edit only `NODES=`:

```bash
vim /var/lib/cpu-cluster-manager/cluster.local.env
bash scripts/install-master.sh
```

If `ADMIN_PASSWORD` is blank, the installer generates a random 32-hex password and writes it to the same mode-600 file.

Legacy pilot state under the shared home is migrated automatically: existing `cluster.local.env`, manager key and known_hosts are copied into host-local state; shared-home private-key copies are removed only after the new master stack is healthy.

A successful install requires FastAPI/Grafana health checks and stable state/restart counts for all six master containers. The installer also publishes only the manager **public** key as `.cluster-manager.pub` on the shared source.

## Initial compute install

The compute uses the master's shared `/home/ysadmin/cpu-cluster-manager` source checkout. Do **not** clone the repository separately on the compute, install Git, or copy JSON/env/key files manually.

On each compute:

```bash
cd /home/ysadmin/cpu-cluster-manager
sudo bash node/install-node.sh
```

The installer automatically reads the shared `.cluster-manager.pub`, verifies the shared source stamp, recomputes the source SHA256, and then deploys to host-local paths.

The installer:

- preserves `/src/rent/home`, `auth`, `work`, `ssh`
- replaces only `/src/rent/image` with the current Git-managed deployment copy
- installs Git-managed sudo/systemd definitions
- installs/updates restricted SSH control
- installs node_exporter with release SHA256 verification
- rebuilds `rent-ubuntu:22.04` only when the stamped `node/rent-image` Git tree differs from the image label
- never recreates an existing `rent-node` merely because a newer image was built
- records the deployed commit and source hash

## Update

GitHub updates and full compute deployment are performed **on each cluster master**, as `ysadmin`, without sudo:

```bash
cd /home/ysadmin/cpu-cluster-manager
bash scripts/update-master.sh
bash scripts/rollout-all-computes.sh
bash scripts/verify-cluster.sh
```

`update-master.sh` fetches and fast-forwards **`origin/main`**, ensures the local checkout is on `main`, and rebuilds the master UI. `rollout-all-computes.sh` stages a checksum-verified **immutable release bundle** on every configured compute node before installing it, preserving existing `rent-node` containers and renter data. Direct `node/update-node.sh` on an NFS-shared working tree is intentionally disabled.

### One-time migration of previously installed masters

Both master nodes previously cloned `dual-os-support` with `--single-branch`. On **each master**, run this once as `ysadmin` before using the regular update workflow:

```bash
cd /home/ysadmin/cpu-cluster-manager
git fetch origin refs/heads/main:refs/remotes/origin/main
git checkout -b main --track origin/main
bash scripts/update-master.sh
bash scripts/rollout-all-computes.sh
bash scripts/verify-cluster.sh
```

`git checkout -b main --track origin/main` explicitly creates the local tracking branch; plain `git checkout main` can fail on an older `--single-branch` clone even after fetching `origin/main`. If a local `main` already exists, use `git checkout main` instead. **Do not force/reset** if Git reports a conflict. Subsequent deployments use only the three update/rollout/verify commands above. The updater also supports safe legacy-branch migration when its **new** version has already been installed.

### Sudo authentication during compute rollout

The rollout checks SSH, host identity, and sudo authorization on **every** compute before modifying any compute. It first tries one sudo password across the cluster. If a node rejects it, the operator can re-enter that node's `ysadmin` sudo password once; it is kept in process memory only, sent via non-PTY SSH standard input, and not written to logs. If a node still rejects authentication, rollout aborts before any compute installation. Log into that node interactively to check `sudo -k; sudo -v; sudo -l` before retrying.

### Rent restart and safe shutdown

Newly created `rent-node` containers use `--restart always`. The compute installer also updates the restart policy of any existing container **in place** (`docker update --restart always`) without recreating it or deleting user data.

The management UI's `Shutdown computes` operation explicitly stops each rent container before powering off the host. With the `always` policy, Docker restarts the container after the host next boots. Updating the restart policy does **not** immediately start a currently stopped container; start it separately if needed:

```bash
sudo docker start rent-node
```

`Shutdown master` is unlocked only after the UI successfully requests compute poweroff and verifies repeated unreachability of both SSH and host monitoring ports. A node that is already unreachable without an acknowledged shutdown remains **unconfirmed**; a network failure is not proof of physical poweroff. Master readiness is intentionally reset when the management service itself restarts.

## Verification

Compute:

```bash
bash node/verify-node.sh
```

Whole cluster from master:

```bash
bash scripts/verify-cluster.sh
```

Whole-cluster verification checks restricted SSH control, compute metrics, deployed commit drift, source hash consistency, master services and generated monitoring targets.

## Deployed source revision

Both master and compute record:

```bash
cat /var/lib/cpu-cluster-manager/deployed-version
```

The record contains commit, branch, role, cluster/host, repository, deployment timestamp and source SHA256.

## Monitoring retention

### Hot

```text
scrape      30s
retention   30d
```

### Archive

Each 5-minute bucket stores `min / avg / max` for host CPU, host memory and max real-filesystem utilization. Compute nodes additionally store `rent-node` CPU, memory and running ratio.

Compute archive cardinality is 18 series/node. Persistent block budget is **32 MB per monitored host (master + compute)**. Archive WAL segment size is **10 MB**, the minimum accepted by the deployed Prometheus 3.14 image. Maximum retention is 5 years.

The block retention limit does not include all transient TSDB head/WAL/compaction overhead, so actual master disk use should be observed during operation.

## Disk alerts

Only disk-capacity alerts are defined for writable real filesystems:

```text
Warning   available < 15% for 15m
Critical  available < 5%  for 5m
```

This applies to both master and compute hosts.

## Network

```text
Master -> Compute :22/tcp    restricted SSH control
Master -> Compute :9100/tcp  Prometheus scrape
```

FastAPI and Grafana bind to master loopback. Master node_exporter is not published on a host port.

## Existing shared `authorized_keys`

Both validated clusters share `/home`, so `ysadmin`'s normal `~/.ssh/authorized_keys` is also infrastructure-shared. The compute installer adds only a forced-command/no-forwarding entry for the manager **public** key. The private manager key remains master-local under `/var/lib/cpu-cluster-manager/ssh`.

## Safety rules

- Never put master secrets under shared `/home` or Cluster 2 `/opt`.
- Never manually edit `/src/rent/image` or installed files under `/usr/local`/`/etc/systemd`.
- Never use `docker compose down -v` during normal operation; it deletes monitoring volumes.
- Update Git on the master only. Compute nodes consume the stamped shared source.
