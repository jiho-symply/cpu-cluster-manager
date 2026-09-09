# CPU Cluster Manager

Cluster 1의 compute node들을 **기존 `ysadmin` 계정**으로 제어하고, Docker 대여 컨테이너 관리와 자원 모니터링을 한 곳에서 운영하기 위한 경량 관리 스택이다.

## Architecture

역할을 명확히 분리한다.

- **FastAPI Control Plane (`:8080`)**
  - `rent-node` 상태 / renter 계정 표시
  - Start / Stop / Restart / Recreate / Logs
  - compute node에는 `ysadmin` + Cluster Manager 전용 SSH key로 접근
  - 상세 자원 그래프는 직접 그리지 않고 Grafana로 연결
- **Grafana (`:3000`)**
  - CPU / Memory / Disk / `rent-node` CPU·Memory
  - Recent dashboard: 최근 30일
  - Long-term dashboard: 최대 3년
- **Prometheus Hot**
  - compute node의 node_exporter / cAdvisor를 30초마다 수집
  - 30일 보관
  - 장기보관용 1시간 aggregate recording series 생성
- **Prometheus Archive**
  - Hot Prometheus의 `archive_*` series만 federation
  - 1시간 간격 수집
  - 3년 보관
- **Alertmanager**
  - Disk capacity alert만 처리
  - Warning: available < 15% for 15m
  - Critical: available < 5% for 5m
  - 현재 외부 receiver(email/Slack/webhook)는 지정하지 않고 local alert state만 유지

```text
Browser
  ├─ FastAPI :8080 ──SSH──> ysadmin@compute-node ──> Docker/rentctl
  └─ Grafana :3000
          ├─ Prometheus Hot (30s / 30d)
          │      ├─ node_exporter :9100
          │      └─ cAdvisor      :8081
          └─ Prometheus Archive (1h / 3y)
```

## Repository layout

```text
cpu-cluster-manager/
├── docker-compose.yml
├── .env.example
├── config/
│   └── nodes.example.yaml
├── manager/
│   └── app/
├── node/
│   ├── cluster-node-admin
│   ├── cluster-node-ssh
│   ├── install-node.sh
│   └── rent-image/
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   └── rules/
│   ├── prometheus-archive/
│   ├── alertmanager/
│   ├── grafana/
│   │   ├── provisioning/
│   │   └── dashboards/
│   └── targets/
└── scripts/
    ├── prepare-master-ssh.sh
    └── render-monitoring-targets.py
```

## Public repository에서 제외되는 정보

다음은 GitHub에 commit하지 않는다.

- 실제 master / compute-node IP
- `.env`
- `config/nodes.yaml`
- SSH private key
- 실제 `known_hosts`
- 생성된 `monitoring/targets/*.json`
- password / token / credential

`.gitignore`가 위 runtime 파일을 제외한다.

---

## 1. Cluster 1 master 준비

`ysadmin`으로 master에 접속한다.

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
cp .env.example .env
cp config/nodes.example.yaml config/nodes.yaml
```

실제 node inventory는 master의 `config/nodes.yaml`에만 작성한다.

```yaml
cluster: cluster1
ssh_user: ysadmin
nodes:
  - name: cpu-01
    host: <COMPUTE_NODE_IP>
    port: 22
  - name: cpu-02
    host: <COMPUTE_NODE_IP>
    port: 22
```

## 2. Cluster Manager 전용 SSH key 생성

master에서:

```bash
./scripts/prepare-master-ssh.sh config/nodes.yaml
```

기본 파일:

```text
/home/ysadmin/.ssh/cluster-manager_ed25519
/home/ysadmin/.ssh/cluster-manager_ed25519.pub
/home/ysadmin/.ssh/cluster-manager_known_hosts
```

- private key는 master에만 보관한다.
- public key만 compute node의 기존 `ysadmin`에 설치한다.
- 기존 사람이 사용하는 `ysadmin` SSH key는 그대로 유지한다.
- Manager용 public key에는 forced command가 적용되어 일반 shell을 열 수 없다.

## 3. 각 compute node bootstrap

master에서 public key를 전달한다.

```bash
scp ~/.ssh/cluster-manager_ed25519.pub \
  ysadmin@<NODE_IP>:/tmp/cluster-manager_ed25519.pub
```

compute node에서:

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
sudo ./node/install-node.sh /tmp/cluster-manager_ed25519.pub
rm -f /tmp/cluster-manager_ed25519.pub
```

`install-node.sh`가 수행하는 작업:

1. 기존 `ysadmin` 존재 확인
2. rent 관리 scripts 설치
3. Cluster Manager forced-command SSH key 추가
4. 제한된 sudo allowlist 설치
5. `node_exporter` container 시작 (`:9100`)
6. cAdvisor container 시작 (`:8081`)

Manager key가 실행할 수 있는 action:

```text
summary
start
stop
restart
recreate
reset-password
logs
```

### Monitoring ports

```text
9100  node_exporter
8081  cAdvisor
```

이 endpoint들은 read-only metrics지만 인증을 두지 않는다. **host firewall/network ACL에서 Cluster 1 master IP만 9100/8081에 접근 가능하도록 제한한다.**

현재 exporter bootstrap은 Cluster 1의 Ubuntu/Docker 환경을 기준으로 한다. CentOS 7 기반 Cluster 2는 별도 호환성 확인 후 적용한다.

## 4. Prometheus target 생성

master의 실제 `config/nodes.yaml`에서 file-SD target을 만든다.

```bash
python3 scripts/render-monitoring-targets.py config/nodes.yaml
```

생성 파일:

```text
monitoring/targets/node-exporter.json
monitoring/targets/cadvisor.json
```

이 파일들은 GitHub에 올라가지 않는다.

## 5. `.env` 설정

최소한 password를 변경한다.

```dotenv
UI_BIND=127.0.0.1
UI_PORT=8080

GRAFANA_BIND=127.0.0.1
GRAFANA_PORT=3000
GRAFANA_BASE_URL=http://127.0.0.1:3000

ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=<LONG_RANDOM_PASSWORD>

SSH_KEY_PATH=/home/ysadmin/.ssh/cluster-manager_ed25519
SSH_KNOWN_HOSTS_PATH=/home/ysadmin/.ssh/cluster-manager_known_hosts
```

FastAPI Basic Auth와 Grafana 초기 admin login은 같은 `ADMIN_USERNAME` / `ADMIN_PASSWORD`를 사용한다.

## 6. Master에서 배포

```bash
docker compose up -d --build
docker compose ps
```

FastAPI health check:

```bash
curl http://127.0.0.1:8080/healthz
```

기본적으로 FastAPI와 Grafana는 master의 loopback에만 bind된다.

관리 PC에서:

```bash
ssh \
  -L 8080:127.0.0.1:8080 \
  -L 3000:127.0.0.1:3000 \
  ysadmin@<MASTER_IP>
```

브라우저:

```text
FastAPI Control Plane  http://127.0.0.1:8080
Grafana                http://127.0.0.1:3000
```

FastAPI의 각 node 행에서 `Recent` / `3y History` 버튼으로 해당 node가 선택된 Grafana dashboard를 바로 연다.

---

## Monitoring policy

### Recent: Prometheus Hot

```text
scrape interval  30 s
retention        30 d
```

Grafana `CPU Cluster · Recent Monitoring`:

- Host CPU
- Host Memory
- filesystem별 Disk usage
- `rent-node` CPU cores
- `rent-node` memory
- disk alert firing 여부

### Long-term: Prometheus Archive

Hot Prometheus가 다음 1시간 aggregate를 recording rule로 만든다.

- CPU: avg / max
- Memory: avg / max
- Filesystem: max
- `rent-node` CPU: avg / max
- `rent-node` Memory: avg / max

Archive Prometheus는 `archive_*` series만 1시간 간격으로 federation하고 **3년** 보관한다.

Grafana `CPU Cluster · Long-term History`에서 다음 범위를 사용할 수 있다.

```text
30d / 90d / 180d / 1y / 2y / 3y
```

3년 데이터는 raw 30-second sample이 아니라 의도적으로 coarse hourly history다.

### Disk alert only

CPU/RAM/container-down alert는 정의하지 않는다.

pseudo filesystem 및 Docker overlay를 제외한 실제 filesystem 기준:

```text
Warning   available < 15% for 15m
Critical  available < 5%  for 5m
```

Critical이 firing이면 동일 filesystem의 Warning은 Alertmanager에서 inhibit한다.

현재 Alertmanager receiver는 local-only다. 실제 email/Slack/webhook destination이 정해지면 receiver만 추가한다.

## Persistent monitoring data

Docker named volume:

```text
prometheus_hot_data       30-day high-resolution metrics
prometheus_archive_data   3-year hourly archive
alertmanager_data         alertmanager state / silences
```

`docker compose down`은 volume을 지우지 않는다.

**`docker compose down -v`는 monitoring history를 삭제하므로 사용하지 않는다.**

Prometheus local TSDB는 master 한 대에 저장되고 replication은 하지 않는다. 3년 archive의 복구 가능성이 중요하면 master filesystem/volume backup 또는 snapshot 정책을 별도로 둔다.

## Update

```bash
git pull
python3 scripts/render-monitoring-targets.py config/nodes.yaml
docker compose up -d --build
```
