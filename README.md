# CPU Cluster Manager

Cluster 1(Ubuntu 20.04)과 Cluster 2(CentOS 7)를 같은 운영 모델로 관리하는 control/monitoring stack이다.

## Service contract

- **FastAPI Control Plane (`127.0.0.1:8080`)**: `rent-node` 상태, renter, Start/Stop/Restart/Recreate/Logs
- **Grafana (`127.0.0.1:3000`)**: host CPU/RAM/disk, `rent-node` CPU/RAM/running history
- **Prometheus Hot**: 30초 scrape, 30일 retention
- **Prometheus Archive**: 5분 bucket의 min/avg/max, 최대 5년
- **Alertmanager**: disk-capacity alert만 정의
- **Compute monitoring**: native node_exporter `:9100` + textfile collector; cAdvisor 없음
- **Control SSH**: 기존 `ysadmin` 계정 + master별 전용 restricted SSH key

## Turn-key boundary

코드는 OS 차이를 자동 감지하지만 아래 네 가지는 public Git repository에 안전하게 넣을 수 없거나 기존 인프라에 의존하므로 사전 조건이다.

1. 각 host에 동작하는 **Docker Engine**이 이미 설치되어 있어야 한다. Installer는 Ubuntu 20.04/CentOS 7의 기존 Docker를 자동 upgrade하지 않는다.
2. 각 host에 기존 **`ysadmin`** 계정이 있어야 하고, master에서 Docker를 사용할 수 있어야 한다.
3. 각 master의 `config/nodes.yaml`에는 실제 compute-node IP/hostname을 사용자가 작성해야 한다.
4. master가 생성한 `cluster-manager_ed25519.pub`은 해당 cluster의 compute node에 안전하게 전달해야 한다. Private key는 master 밖으로 복사하지 않는다.

또한 network ACL은 master→compute TCP/22 및 TCP/9100을 허용해야 한다. Installer는 사이트별 firewall/iptables 정책을 자동 변경하지 않는다.

## Before merging to main

현재 검증 중인 구현은 `dual-os-support` branch에 있다. 이 branch가 `main`에 merge되기 전에는 plain `git clone`만으로 최신 installer가 checkout되지 않는다.

## Master install

Cluster 1:

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
cp config/nodes.example.yaml config/nodes.yaml
# config/nodes.yaml의 host를 실제 값으로 수정
bash scripts/install-master.sh config/nodes.yaml
```

Cluster 2는 `config/nodes.cluster2.example.yaml`을 사용한다.

`install-master.sh`는 다음을 수행한다.

1. Ubuntu 20.04 / CentOS 7, kernel, SELinux, Docker, `ysadmin` preflight
2. `.env` 생성 및 random admin password 생성
3. master 전용 SSH key 생성
4. `known_hosts`에 새 node만 추가하며 기존 trust entry는 보존
5. Prometheus target 생성 (host Python 불필요)
6. archive block cap 계산: **32 MB × compute-node count**
7. FastAPI / Prometheus Hot / Prometheus Archive / Alertmanager / Grafana 시작
8. FastAPI/Grafana health check

Host에 Compose가 있으면 그것을 사용한다. 없으면 `docker/compose:1.29.2`를 ephemeral client로 사용하므로 host package 설치가 필요 없다.

## Compute-node install

Master가 만든 public key만 compute node로 전달한다.

```bash
scp ~/.ssh/cluster-manager_ed25519.pub \
  ysadmin@<NODE_IP>:/tmp/cluster-manager_ed25519.pub
```

Compute node:

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
sudo bash node/install-node.sh /tmp/cluster-manager_ed25519.pub
rm -f /tmp/cluster-manager_ed25519.pub
```

Fresh node에서는 installer가 자동으로:

- rent Ubuntu 22.04 image build
- `/src/rent` persistent layout 생성
- `rent-node` 최초 생성
- `engclusterXXX` renter 생성 및 **random temporary password 1회 출력**
- restricted manager SSH key 설치
- native node_exporter 설치 및 checksum 검증
- 30초 systemd timer 기반 `rent-node` metrics 설치
- container/metrics health check

재실행 시에는 기존 `rent-node`, `/src/rent` 데이터, renter password를 초기화하지 않는다.

## End-to-end verification

모든 compute node 설치 후 master에서:

```bash
bash scripts/verify-cluster.sh config/nodes.yaml
```

검증 항목:

- 각 node restricted SSH control path
- 각 node `:9100/metrics`
- custom `cluster_rent_container_*` metric
- master의 FastAPI/Prometheus/Alertmanager/Grafana container state

## Monitoring

### Hot

```text
scrape      30s
retention   30d
```

필요한 metric만 저장하며 host CPU는 total utilization 계산에 필요한 idle counter만 유지해 고-core 서버 cardinality를 줄인다.

### Archive

각 5분 bucket마다 아래 항목의 `min / avg / max`를 저장한다.

| Resource | Aggregate |
|---|---|
| Host CPU utilization | min / avg / max |
| Host memory utilization | min / avg / max |
| Most-used real filesystem utilization | min / avg / max |
| `rent-node` CPU cores | min / avg / max |
| `rent-node` memory usage | min / avg / max |
| `rent-node` running ratio | min / avg / max |

총 **18 series/node**, bucket `5m`, 최대 retention `5y`다.

Archive persistent block cap은 **32 MB/node**이고 WAL segment는 8 MB로 축소한다. `retention.time`과 `retention.size` 중 먼저 도달한 조건이 적용된다. 이는 `<100 MB/node`를 목표로 한 보수적 설계지만 Prometheus compaction/WAL/head의 순간적 overhead까지 수학적으로 hard-cap하는 것은 아니다. Pilot 후 master에서 실제 `du`를 확인해야 한다.

Grafana는 별도 custom resolution selector 없이 datasource 최소 interval `5m`과 표준 `$__interval`을 사용해 조회 기간/화면 폭에 따라 해상도를 자동 조절한다.

## Disk alert only

```text
Warning   available < 15% for 15m
Critical  available < 5%  for 5m
```

pseudo filesystem과 Docker overlay는 제외한다. 현재 Alertmanager receiver는 local-only이므로 Grafana/Prometheus에서 firing 상태는 보이지만 외부 email/Slack 전송은 receiver를 추가하기 전까지 발생하지 않는다.

## Network

```text
Master -> Compute :22/tcp    restricted SSH control
Master -> Compute :9100/tcp  Prometheus scrape
```

`9100`은 인증 없는 read-only metrics endpoint이므로 대응 master/network에서만 접근하도록 제한한다.

FastAPI/Grafana는 master loopback에 bind된다. 관리 PC에서는 SSH tunnel을 사용한다.

```bash
ssh -L 8080:127.0.0.1:8080 -L 3000:127.0.0.1:3000 ysadmin@<MASTER_IP>
```

## Persistent data

Compute:

```text
/src/rent/home
/src/rent/work
/src/rent/ssh
/src/rent/auth
```

Master Docker volumes:

```text
prometheus_hot_data
prometheus_archive_data
alertmanager_data
```

`docker compose down -v` 또는 이에 준하는 volume 삭제는 monitoring history를 삭제하므로 사용하지 않는다.

자세한 OS별 설명은 `docs/DUAL_OS_DEPLOYMENT.md`를 참고한다.
