# Dual-OS deployment notes

지원 대상:

- Cluster 1: Ubuntu 20.04
- Cluster 2: CentOS 7
- Host admin account: existing `ysadmin`
- Rent environment: Ubuntu 22.04 `rent-node` Docker container

## Common contract

두 OS 모두 같은 installer를 사용한다. OS별 차이는 `scripts/preflight.sh`와 SELinux-compatible bind mount가 흡수한다.

Compute node는 native `node_exporter` + textfile collector를 사용한다. cAdvisor를 쓰지 않으므로 CentOS 7의 cgroup/privileged-container 예외를 피한다.

## Preconditions

Installer가 자동으로 만들지 않는 인프라 조건:

1. 동작 중인 Docker Engine
2. `ysadmin` host account
3. master→compute TCP/22, TCP/9100 network reachability
4. master의 실제 `config/nodes.yaml`
5. master-generated SSH public key의 compute-node 전달
6. outbound access required for first-time image/package download (Ubuntu archive and GitHub node_exporter release)

Installer는 Docker Engine, host firewall, iptables, firewalld를 자동 upgrade/reconfigure하지 않는다.

## Master

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
cp config/nodes.example.yaml config/nodes.yaml
# Cluster 2: config/nodes.cluster2.example.yaml 사용
# 실제 host 값 수정
bash scripts/install-master.sh config/nodes.yaml
```

Master installer는 host Python에 의존하지 않는다. Compose plugin/standalone이 없으면 `docker/compose:1.29.2` ephemeral client를 사용한다.

첫 실행 시 `.env` mode 600을 만들고 default admin password를 random 32-hex password로 교체한다.

SSH `known_hosts`는 재설치 시 비우지 않는다. 이미 신뢰한 host key가 변경되면 `StrictHostKeyChecking`이 실패하게 두며 자동 수용하지 않는다.

## Compute

Master에서:

```bash
scp ~/.ssh/cluster-manager_ed25519.pub ysadmin@<NODE_IP>:/tmp/cluster-manager_ed25519.pub
```

Compute node에서:

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
git checkout dual-os-support
sudo bash node/install-node.sh /tmp/cluster-manager_ed25519.pub
rm -f /tmp/cluster-manager_ed25519.pub
```

Fresh install은 rent image build, `/src/rent` 초기화, `rent-node` 생성, random renter temporary password 발급, monitoring 설치까지 수행한다.

재실행은 기존 `rent-node`, `/src/rent`, renter password를 보존한다.

CentOS/RHEL SELinux enforcing 환경을 위해 rent persistent bind mount는 `:Z`를 사용한다.

## Monitoring

Compute node:

- node_exporter v1.12.1 static binary
- release SHA256 검증
- systemd service
- 30초 timer가 `docker stats --no-stream rent-node`를 textfile metric으로 기록
- TCP/9100 only

Master:

- Hot Prometheus: 30s, 30d
- Archive Prometheus: 5m aggregate min/avg/max, max 5y
- Grafana automatic `$__interval`
- disk alert only

Archive는 18 series/node를 유지하며 persistent block cap은 32 MB/node다. Archive WAL segment는 8 MB로 축소한다. 이 설정은 `<100 MB/node`를 목표로 하지만 compaction/head/WAL 순간 overhead까지 strict hard quota로 보장하지는 않는다.

## Verification

모든 compute node 설치 후 master에서:

```bash
bash scripts/verify-cluster.sh config/nodes.yaml
```

이 검증이 통과한 뒤 운영 전환한다.

## OS caveats

### Ubuntu 20.04

현재 Docker package support 범위 밖이므로 installer가 Docker를 교체하지 않는다. 기존 Docker가 정상 동작해야 한다.

### CentOS 7

EOL이며 current Docker CE package 대상이 아니다. 기존 Docker/kernel을 그대로 사용하고 preflight 결과를 확인한다. 매우 오래된 3.10 kernel은 경고한다.

실제 Docker Engine 버전이 충분히 오래된 경우 최신 Prometheus/Grafana container image가 실행되지 않을 수 있으므로, 최초 배포는 각 cluster에서 compute 1대 + master 1대 pilot으로 검증해야 한다.

## Turn-key definition

`main`에 이 branch가 merge된 이후에는 installer 관점에서:

- master: inventory 작성 후 `bash scripts/install-master.sh`
- compute: public key 전달 후 `sudo bash node/install-node.sh`
- master: `bash scripts/verify-cluster.sh`

세 단계가 최종 운영 절차다.
