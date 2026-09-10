# CPU Cluster Manager

Cluster 1(Ubuntu 20.04)과 Cluster 2(CentOS 7)를 동일한 운영 모델로 관리하는 경량 control/monitoring stack이다.

## Operating principles

1. **GitHub is the source of truth for code/config templates.**
   - Dockerfile / rent scripts
   - compute management scripts
   - sudo policy
   - systemd units
   - FastAPI
   - Docker Compose
   - Prometheus / Grafana / Alertmanager config
   - installer / updater / verifier
2. **Operator-managed local configuration is one file only:** `cluster.local.env`.
3. `/src/rent/image`, `/usr/local/bin`, `/usr/local/sbin`, `/etc/systemd/system`, `/etc/sudoers.d`의 관련 파일은 Git source에서 설치된 **deployment copies**다. 직접 수정하지 않는다.
4. Runtime data/secrets that require their own file format are generated automatically and are not manually copied between configuration files.
5. 배포 버전은 Git tag/release가 아니라 **Git commit SHA**로 기록한다.

## One local file

Master에서 사람이 직접 관리하는 파일은 `cluster.local.env` 하나뿐이다. Git에는 commit되지 않으며 mode 600이다.

```dotenv
CLUSTER=cluster1
NODES=kfai-cpu-01@192.168.100.11,kfai-cpu-02@192.168.100.12
ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=<generated automatically>
UI_PORT=8080
GRAFANA_PORT=3000
```

`NODES`에는 반드시 각 cluster의 private management IP를 사용한다.

- Cluster 1: `192.168.100.x`
- Cluster 2: `172.20.x.x`

Prometheus target JSON은 installer가 이 파일에서 자동 생성한다. 별도의 `.env`, `nodes.yaml`, JSON을 사람이 복사/관리하지 않는다.

### Automatically managed state

다음은 secret/state이지만 사람이 onefile에서 복사 관리할 대상이 아니다.

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
- **Compute monitoring**: native node_exporter `:9100` + Git-managed systemd timer/textfile collector
- **Control SSH**: existing `ysadmin` + master-specific restricted key

## Repository ownership map

```text
cpu-cluster-manager/
├── cluster.local.env.example     # only local-config template
├── docker-compose.yml            # master services
├── manager/                      # FastAPI source
├── monitoring/                   # Prometheus/Grafana/Alertmanager source
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
└── scripts/
    ├── install-master.sh
    ├── update-master.sh
    ├── verify-cluster.sh
    ├── prepare-master-ssh.sh
    ├── render-monitoring-targets.sh
    ├── write-deploy-state.sh
    └── preflight.sh
```

## Preconditions already validated on the two clusters

- existing `ysadmin`
- Docker Engine 20.10 / API 1.41 class
- Docker Compose v2.6.0 on both masters
- Ubuntu 20.04 master/compute and CentOS 7 master/compute
- CentOS 7 kernel 3.10.0-1160
- Ubuntu 22.04 rent container runtime
- `:Z` bind mount
- outbound Docker/GitHub/Ubuntu package access
- private master→compute SSH paths

Installer does not replace Docker Engine and does not rewrite site firewall/iptables policy.

## Initial master install

Current implementation is on `dual-os-support` until merged into `main`.

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
bash scripts/install-master.sh
```

On the very first run, the installer creates:

```text
cluster.local.env
```

and exits. Edit only `NODES=` if the autodetected `CLUSTER=` is correct, then run again:

```bash
vim cluster.local.env
bash scripts/install-master.sh
```

A random admin password is written into the same file automatically if `ADMIN_PASSWORD` is blank.

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

- preserves existing `/src/rent/home`, `auth`, `work`, `ssh`
- replaces `/src/rent/image` with the current Git-managed source
- installs Git-managed sudo/systemd definitions
- installs/updates restricted SSH control
- installs node_exporter
- builds the rent image only when the Git `node/rent-image` tree changed
- never recreates an existing running `rent-node` merely because the image was rebuilt
- creates `rent-node` only on a fresh node
- records the deployed Git commit

## Update

No local file copying is required.

Master:

```bash
bash scripts/update-master.sh
```

Compute:

```bash
bash node/update-node.sh
```

Both commands use `git pull --ff-only` and refuse to overwrite tracked local modifications.

## Verify

Compute locally:

```bash
bash node/verify-node.sh
```

Whole cluster from master:

```bash
bash scripts/verify-cluster.sh
```

## Deployed source revision

Every successful install/update records:

```bash
cat /var/lib/cpu-cluster-manager/deployed-version
```

Example:

```text
commit=<git-sha>
branch=<branch>
role=compute
host=kfai-cpu-01
deployed_at=<timestamp>
repository=<origin>
```

No Git tag/release workflow is required.

## Monitoring retention

### Hot

```text
scrape      30s
retention   30d
```

### Archive

Each 5-minute bucket stores `min / avg / max` for:

- host CPU utilization
- host memory utilization
- most-used real filesystem utilization
- `rent-node` CPU
- `rent-node` memory
- `rent-node` running ratio

This is 18 archive series per compute node. Maximum retention is 5 years. Persistent archive block budget is 32 MB per compute node and Archive WAL segment size is 8 MB. Grafana uses its normal `$__interval` behavior rather than a custom resolution selector.

## Network

```text
Master -> Compute :22/tcp    restricted SSH control
Master -> Compute :9100/tcp  Prometheus scrape
```

FastAPI and Grafana bind to master loopback. Access them through an administrator SSH tunnel when needed.

## Runtime data boundary

Do not manually edit Git-deployed copies. Do not delete runtime state unintentionally.

```text
/src/rent/image       Git-deployed copy; replaceable
/src/rent/home        persistent renter data; preserve
/src/rent/work        persistent renter data; preserve
/src/rent/auth        persistent auth state; preserve
/src/rent/ssh         persistent SSH state; preserve
```

`docker compose down -v` deletes Prometheus/Alertmanager volumes and must not be used during normal updates.
