# CPU Cluster Manager

Cluster 1(Ubuntu 20.04)과 Cluster 2(CentOS 7)를 같은 운영 모델로 관리하기 위한 경량 control/monitoring stack이다.

## Architecture

- **FastAPI Control Plane (`:8080`)**
  - `rent-node` 상태 / renter 계정 표시
  - Start / Stop / Restart / Recreate / Logs
  - 각 compute node에는 기존 `ysadmin` + Cluster Manager 전용 SSH key로 접근
  - 상세 자원 history는 Grafana로 연결
- **Grafana (`:3000`)**
  - Host CPU / Memory / Disk
  - `rent-node` CPU / Memory / running ratio
  - Recent: 30초 수집 기반 최근 30일
  - Long-term: 5분 bucket min/avg/max, 최대 5년
- **Prometheus Hot**
  - compute node의 native `node_exporter:9100`을 30초마다 scrape
  - 30일 보관
  - 5분 장기 aggregate recording series 생성
- **Prometheus Archive**
  - Hot Prometheus의 `archive_*5m` series만 federation
  - 5분 간격 저장
  - 최대 5년
  - persistent block budget: **80MB × compute-node count**
- **Alertmanager**
  - Disk capacity alert만 처리
  - Warning: available < 15% for 15m
  - Critical: available < 5% for 5m

```text
Browser
  ├─ FastAPI :8080 ──SSH──> ysadmin@compute-node ──> Docker/rentctl
  └─ Grafana :3000
          ├─ Prometheus Hot (30s / 30d)
          │      └─ node_exporter :9100
          │              ├─ host metrics
          │              └─ textfile metrics from docker stats rent-node
          └─ Prometheus Archive (5m aggregate / max 5y)
```

## Why no cAdvisor

관리 대상 container가 노드당 `rent-node` 하나이므로 cAdvisor 전체를 띄우지 않는다. 각 compute node의 systemd timer가 30초마다 `docker stats --no-stream rent-node`를 읽어 node_exporter textfile collector metric으로 기록한다.

이 구조는 Ubuntu 20.04와 CentOS 7에서 cgroup mount 방식 차이를 피하고 monitoring port도 `9100` 하나로 줄인다.

## Repository layout

```text
cpu-cluster-manager/
├── docker-compose.yml
├── .env.example
├── config/
│   ├── nodes.example.yaml
│   └── nodes.cluster2.example.yaml
├── manager/
├── node/
│   ├── install-node.sh
│   ├── install-monitoring.sh
│   ├── rent-node-metrics.sh
│   ├── cluster-node-admin
│   ├── cluster-node-ssh
│   └── rent-image/
├── monitoring/
│   ├── prometheus/
│   ├── prometheus-archive/
│   ├── alertmanager/
│   ├── grafana/
│   └── targets/
├── scripts/
│   ├── preflight.sh
│   ├── compose.sh
│   ├── install-master.sh
│   ├── prepare-master-ssh.sh
│   └── render-monitoring-targets.py
└── docs/
    └── DUAL_OS_DEPLOYMENT.md
```

## Public repository에서 제외되는 정보

다음은 commit하지 않는다.

- 실제 master / compute-node IP
- `.env`
- `config/nodes.yaml`
- SSH private key
- 실제 `known_hosts`
- 생성된 `monitoring/targets/*.json`
- password / token / credential

## Cluster inventory

Cluster 1 example:

```yaml
cluster: cluster1
platform: ubuntu20
ssh_user: ysadmin
nodes:
  - name: cpu-01
    host: <COMPUTE_NODE_IP>
    port: 22
```

Cluster 2 example:

```yaml
cluster: cluster2
platform: centos7
ssh_user: ysadmin
nodes:
  - name: cpu-07
    host: <COMPUTE_NODE_IP>
    port: 22
```

실제 inventory는 각 master의 `config/nodes.yaml`에만 둔다.

## Master install

Master에서도 OS 차이는 installer가 감지한다. 기존 Docker Engine은 자동 교체/upgrade하지 않는다.

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
cp config/nodes.example.yaml config/nodes.yaml   # Cluster 2는 cluster2 example 사용
# config/nodes.yaml 수정
./scripts/install-master.sh config/nodes.yaml
```

`install-master.sh`가 수행하는 작업:

1. Ubuntu 20.04 / CentOS 7, kernel, Docker, Compose, `ysadmin` preflight
2. Cluster Manager 전용 SSH key 준비
3. Prometheus file-SD target 생성
4. compute-node 수 계산
5. `ARCHIVE_RETENTION_SIZE = 80MB × node_count`를 `.env`에 기록
6. Compose config 검증
7. FastAPI / Prometheus Hot / Prometheus Archive / Alertmanager / Grafana 시작

## Compute-node install

Master에서 public key만 전달한다.

```bash
scp ~/.ssh/cluster-manager_ed25519.pub \
  ysadmin@<NODE_IP>:/tmp/cluster-manager_ed25519.pub
```

Compute node에서:

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
sudo ./node/install-node.sh /tmp/cluster-manager_ed25519.pub
rm -f /tmp/cluster-manager_ed25519.pub
```

Installer가 수행하는 작업:

1. OS/Docker/kernel preflight
2. 기존 `ysadmin` 확인
3. rent management scripts 설치
4. restricted manager SSH public key 추가
5. `cluster-node-admin` + sudo allowlist 설치
6. native node_exporter 설치
7. `rent-node-metrics` systemd service/timer 설치
8. `:9100/metrics` health check

Monitoring history는 compute node에 저장하지 않는다. Compute node에는 node_exporter binary와 작은 textfile만 존재하고, 실제 TSDB history는 cluster master의 Prometheus volume에 저장된다.

## Network contract

```text
Master -> Compute :22/tcp    SSH control
Master -> Compute :9100/tcp  Prometheus metrics
```

`9100`은 인증 없는 read-only metrics endpoint이므로 해당 cluster master에서만 접근 가능하도록 firewall/network ACL을 제한한다.

## Monitoring policy

### Recent / Hot

```text
scrape interval  30s
retention        30d
```

### Long-term / Archive

각 **5분 bucket**마다 다음 값을 기록한다.

| Resource | Stored aggregate |
|---|---|
| Host CPU utilization | min / avg / max |
| Host memory utilization | min / avg / max |
| Most-used real filesystem utilization | min / avg / max |
| `rent-node` CPU cores | min / avg / max |
| `rent-node` memory usage | min / avg / max |
| `rent-node` running ratio | min / avg / max |

따라서 장기 cardinality는 기본적으로 **18 series / compute node**로 고정된다.

```text
bucket            5m
maximum retention 5y
archive series    18/node
block budget      80MB/node
```

Prometheus Archive에는 time retention과 size retention을 동시에 적용한다. 둘 중 먼저 도달하는 조건이 오래된 block을 제거한다.

Prometheus 공식 가이드의 평균 1–2 bytes/sample을 적용하면 18 series × 5분 × 5년은 약 9.47M samples/node, 즉 sample chunk payload 기준 약 9–19MB/node 규모다. 실제 index, metadata, compaction overhead는 별도로 존재하므로 persistent block cap을 80MB/node로 두어 100MB/node 운영 목표에 여유를 둔다.

주의: Prometheus `retention.size`는 persistent block을 제한한다. WAL/head와 compaction 중 일시적 중복 공간까지 포함한 물리적 총 사용량을 정확히 100MB/node로 hard-limit하는 기능은 아니다. 이 overhead는 cluster master의 하나의 Archive Prometheus가 모든 노드에 대해 공유한다.

Grafana Long-term dashboard는 `min / avg / max`를 동시에 보여주며 다음 범위를 선택할 수 있다.

```text
30d / 90d / 180d / 1y / 2y / 3y / 4y / 5y
```

## Disk alert only

CPU/RAM/container-down alert는 정의하지 않는다.

```text
Warning   available < 15% for 15m
Critical  available < 5%  for 5m
```

pseudo filesystem / Docker overlay는 제외한다.

## Persistent monitoring data

```text
prometheus_hot_data       30-day high-resolution metrics
prometheus_archive_data   5-minute aggregate, max 5 years
alertmanager_data         alert state / silences
```

`docker compose down`은 volume을 유지한다.

**`docker compose down -v`는 monitoring history를 삭제하므로 사용하지 않는다.**
