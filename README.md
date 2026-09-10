# CPU Cluster Manager

Cluster 1(Ubuntu 20.04)과 Cluster 2(CentOS 7)를 동일한 운영 모델로 관리하는 경량 control/monitoring stack이다.

## Operating model

- **GitHub is the source of truth** for Dockerfile, rent scripts, compute management scripts, sudoers, systemd units, FastAPI, Docker Compose, Prometheus, Grafana, Alertmanager, installers/updaters/verifiers.
- 운영자가 직접 관리하는 로컬 설정/secret은 **`cluster.local.env` 한 파일뿐**이다.
- `/src/rent/image`, `/usr/local/bin`, `/usr/local/sbin`, `/etc/systemd/system`, `/etc/sudoers.d`의 관련 파일은 Git source에서 설치되는 deployment copy다. 직접 수정하지 않는다.
- runtime state는 각 서비스가 자동 관리하며 별도 설정 파일을 사람이 복사하지 않는다.
- Git tag/release workflow는 쓰지 않는다. 실제 배포 버전은 **Git commit SHA**로 기록한다.

## One operator-managed file

첫 master 설치 시 `cluster.local.env.example`에서 `cluster.local.env`가 자동 생성된다. 실제 파일은 Git-ignored, mode 600이다.

```dotenv
CLUSTER=cluster1
NODES=kfai-cpu-01@192.168.100.11,kfai-cpu-02@192.168.100.12
ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=<generated automatically>
UI_PORT=8080
GRAFANA_PORT=3000
```

`NODES`에는 해당 cluster의 private management IP를 사용한다.

- Cluster 1: `192.168.100.x`
- Cluster 2: `172.20.x.x`

별도의 `.env`, `nodes.yaml`, 수동 Prometheus JSON 관리는 없다. Prometheus target JSON은 installer가 자동 생성한다.

### Automatically managed state

다음은 secret/state이지만 사용자가 onefile에서 복사 관리할 대상이 아니다.

```text
/home/ysadmin/.ssh/cluster-manager_ed25519       master-generated private key
/home/ysadmin/.ssh/cluster-manager_known_hosts  SSH trust state
/var/lib/cpu-cluster-manager/                   deployed commit / stored manager public key
/src/rent/auth                                  renter auth DB
/src/rent/ssh                                   rent-node SSH host keys
Prometheus Docker volumes                       metrics history
```

Private SSH key는 master 밖으로 복사하지 않는다. Compute node에는 public key만 전달한다.

## Service contract

- **FastAPI Control Plane (`127.0.0.1:8080`)**: `rent-node` 상태/renter, Start/Stop/Restart/Recreate/Logs
- **Grafana (`127.0.0.1:3000`)**: host CPU/RAM/disk, `rent-node` CPU/RAM/running history
- **Prometheus Hot**: 30초 scrape, 30일 retention
- **Prometheus Archive**: 5분 min/avg/max aggregate, 최대 5년
- **Alertmanager**: disk-capacity alert only
- **Master monitoring**: Dockerized node_exporter, internal Compose network only
- **Compute monitoring**: native node_exporter `:9100` + Git-managed systemd timer/textfile collector
- **Control SSH**: existing `ysadmin` + master-specific restricted key

Master 자체의 filesystem도 node_exporter로 수집하므로 Prometheus archive가 위치한 master disk도 같은 disk-capacity alert 대상이다.

## Repository ownership map

```text
cpu-cluster-manager/
├── cluster.local.env.example
├── docker-compose.yml
├── manager/
├── monitoring/
├── node/
│   ├── install-node.sh
│   ├── update-node.sh
│   ├── verify-node.sh
│   ├── cluster-node-admin
│   ├── cluster-node-ssh
│   ├── rent-node-metrics.sh
│   ├── sudoers/
│   │   └── cpu-cluster-manager
│   ├── systemd/
│   │   ├── node-exporter.service
│   │   ├── rent-node-metrics.service
│   │   └── rent-node-metrics.timer
│   └── rent-image/
│       ├── Dockerfile
│       ├── rentctl.sh
│       ├── renter-account.sh
│       └── ...
├── scripts/
│   ├── install-master.sh
│   ├── update-master.sh
│   ├── verify-cluster.sh
│   ├── prepare-master-ssh.sh
│   ├── render-monitoring-targets.sh
│   ├── write-deploy-state.sh
│   ├── preflight.sh
│   └── static-check.sh
└── .github/workflows/ci.yml
```

## Validated infrastructure baseline

The actual two clusters have been checked with:

- existing `ysadmin`, passwordless sudo and Docker group access
- Docker Engine 20.10 / API 1.41 class
- Docker Compose v2.6.0 on both masters
- Ubuntu 20.04 master/compute and CentOS 7 master/compute
- CentOS 7 kernel 3.10.0-1160
- Prometheus 3.14.0 / Alertmanager 0.34.0 / Grafana 13.2.1 container execution on both masters
- Ubuntu 22.04 rent container execution and `:Z` bind mounts on both compute OS families
- Ubuntu package access for fresh rent-image builds
- private master→compute SSH paths
- existing renter naming convention (`engclusterXXX`, UID `20000 + public/default-route IPv4 last octet`)

Installer does not replace Docker Engine and does not rewrite site firewall/iptables policy.

## Initial master install

Current implementation remains on `dual-os-support` until pilot validation is complete.

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
bash scripts/install-master.sh
```

First run creates `cluster.local.env` and exits. Confirm auto-detected `CLUSTER` and edit only `NODES=` using private management IPs:

```bash
vim cluster.local.env
bash scripts/install-master.sh
```

If `ADMIN_PASSWORD` is blank, the installer generates a random 32-hex password and writes it back to the same file.

## Initial compute install

From the corresponding master:

```bash
scp ~/.ssh/cluster-manager_ed25519.pub \
  ysadmin@<COMPUTE_PRIVATE_IP>:/tmp/cluster-manager_ed25519.pub
```

Compute node:

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
sudo bash node/install-node.sh /tmp/cluster-manager_ed25519.pub
rm -f /tmp/cluster-manager_ed25519.pub
```

The installer:

- preserves `/src/rent/home`, `auth`, `work`, `ssh`
- replaces `/src/rent/image` with the current Git-managed deployment copy
- installs Git-managed sudo/systemd definitions
- installs/updates restricted SSH control
- installs node_exporter and verifies its release checksum
- rebuilds `rent-ubuntu:22.04` only when the Git `node/rent-image` tree differs from the image label
- never recreates an existing `rent-node` merely because a newer image was built
- creates `rent-node` only on a fresh node
- records the deployed Git commit

## Update

No configuration copying is required.

Master:

```bash
bash scripts/update-master.sh
```

Compute:

```bash
bash node/update-node.sh
```

Both use `git pull --ff-only` and refuse to overwrite tracked local modifications.

## Verification

Compute locally:

```bash
bash node/verify-node.sh
```

Whole cluster from master:

```bash
bash scripts/verify-cluster.sh
```

Whole-cluster verification checks restricted SSH control, compute metrics, deployed commit drift, master service state and the generated master node_exporter target.

## Deployed source revision

Every successful install/update records:

```bash
cat /var/lib/cpu-cluster-manager/deployed-version
```

The file contains commit, branch, role, cluster/host and deployment timestamp. No tag/release management is required.

## Monitoring retention

### Hot

```text
scrape      30s
retention   30d
```

### Archive

Each 5-minute bucket stores `min / avg / max` for host CPU, host memory and max real-filesystem utilization. Compute nodes additionally store `rent-node` CPU, memory and running ratio.

Compute node archive cardinality is 18 series/node. Maximum retention is 5 years. Persistent block budget is **32 MB per monitored host (master + compute)** and Archive WAL segment size is 8 MB. `retention.time` and `retention.size` both apply; whichever is reached first removes old blocks.

Grafana uses its standard Prometheus datasource minimum interval (`5m`) and `$__interval`; there is no custom resolution selector.

## Disk alerts

Only disk-capacity alerts are defined for writable real filesystems:

```text
Warning   available < 15% for 15m
Critical  available < 5%  for 5m
```

This applies to both master and compute hosts. CPU/RAM/container-down alerts are intentionally not defined.

## Network

```text
Master -> Compute :22/tcp    restricted SSH control
Master -> Compute :9100/tcp  Prometheus scrape
```

FastAPI and Grafana bind to master loopback. Master node_exporter is not published on a host port; Prometheus reaches it only through the internal Compose network.

## Runtime data boundary

```text
/src/rent/image       Git-deployed copy; replaceable
/src/rent/home        persistent renter data; preserve
/src/rent/work        persistent renter data; preserve
/src/rent/auth        persistent auth state; preserve
/src/rent/ssh         persistent SSH state; preserve
```

Do not manually edit Git-deployed copies. `docker compose down -v` deletes monitoring volumes and must not be used during normal updates.
