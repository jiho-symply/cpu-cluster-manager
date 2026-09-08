# CPU Cluster Manager

A small SSH-based web UI for managing one `rent-node` Docker container per compute node.

The repository contains both:

- `manager/`: FastAPI management UI, intended to run as a Docker container on the Cluster 1 master node.
- `node/`: the compute-node management wrapper plus the existing `rent` container image/lifecycle scripts.

The operating model is intentionally simple:

- every server is administratively managed through the existing `ysadmin` account;
- the web manager uses a **dedicated SSH key pair** generated on the Cluster 1 master;
- no extra Linux account such as `cluster-ui` is created;
- the manager key is restricted with an SSH forced command, so that key cannot open a normal `ysadmin` shell;
- the manager never mounts `/var/run/docker.sock` and never exposes the Docker remote API.

## Repository layout

```text
cpu-cluster-manager/
├── docker-compose.yml
├── .env.example
├── config/
│   └── nodes.example.yaml
├── manager/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/
├── node/
│   ├── cluster-node-admin
│   ├── cluster-node-ssh
│   ├── install-node.sh
│   └── rent-image/          # existing rent container code
└── scripts/
    └── prepare-master-ssh.sh
```

## What belongs in GitHub

This repository is public. Keep only examples and non-secret defaults in Git.

Do **not** commit:

- real master/compute-node IP addresses or host inventory;
- `.env`;
- `config/nodes.yaml`;
- SSH private keys;
- real `known_hosts` files;
- passwords or other credentials.

`.gitignore` already excludes `.env`, `config/nodes.yaml`, and `secrets/`.

## 1. Clone on the Cluster 1 master

Log in to the master as `ysadmin` and clone the repository:

```bash
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
cp .env.example .env
cp config/nodes.example.yaml config/nodes.yaml
```

Edit `config/nodes.yaml` only on the master with the actual Cluster 1 compute-node addresses:

```yaml
cluster: cluster1
ssh_user: ysadmin
nodes:
  - name: cpu-01
    host: <COMPUTE_NODE_IP>
    port: 22
```

## 2. Generate the manager SSH key on the master

Generate a dedicated key pair and build the manager `known_hosts` file:

```bash
./scripts/prepare-master-ssh.sh config/nodes.yaml
```

Default paths:

```text
/home/ysadmin/.ssh/cluster-manager_ed25519       # private key: master only
/home/ysadmin/.ssh/cluster-manager_ed25519.pub   # public key: install on compute nodes
/home/ysadmin/.ssh/cluster-manager_known_hosts   # master only
```

The private key must never be copied to a compute node or committed to GitHub.

`ssh-keyscan` populates the file automatically. For a stricter deployment, verify each node's SSH host-key fingerprint through an independent trusted channel before relying on the generated `known_hosts` file.

## 3. Bootstrap each compute node once

The compute nodes must already have the normal administrative `ysadmin` account. No new account is created by this project.

Copy only the manager **public** key to a compute node using your existing administrative access:

```bash
scp ~/.ssh/cluster-manager_ed25519.pub \
  ysadmin@<NODE_IP>:/tmp/cluster-manager_ed25519.pub
```

Then log in normally and install the node-side code:

```bash
ssh ysadmin@<NODE_IP>
git clone https://github.com/jiho-symply/cpu-cluster-manager.git
cd cpu-cluster-manager
sudo ./node/install-node.sh /tmp/cluster-manager_ed25519.pub
rm -f /tmp/cluster-manager_ed25519.pub
```

`install-node.sh`:

1. verifies that the existing `ysadmin` account exists;
2. installs the rent scripts under `/src/rent/image/`;
3. installs `/usr/local/sbin/cluster-node-admin`;
4. installs the small forced-command dispatcher `/usr/local/bin/cluster-node-ssh`;
5. **appends** the manager public key to `/home/ysadmin/.ssh/authorized_keys` without replacing existing human/admin keys;
6. restricts that key to the fixed manager actions;
7. installs a narrow `NOPASSWD` sudo allowlist for those actions only.

The manager key can run only:

```text
summary
start
stop
restart
recreate
reset-password
logs
```

It cannot open an interactive shell or use SSH port/agent/X11 forwarding. Your existing `ysadmin` SSH keys are unaffected and continue to provide normal administrative access.

The UI intentionally does **not** expose the destructive `rentctl.sh reset` or `setup` commands.

Verify from the master:

```bash
ssh -i ~/.ssh/cluster-manager_ed25519 \
  -o IdentitiesOnly=yes \
  ysadmin@<NODE_IP> summary
```

A successful response contains fields such as `HOST_CPU`, `HOST_MEM`, and `CONTAINER_STATUS`.

Trying to use the manager key without one of the allowed actions should fail by design:

```bash
ssh -i ~/.ssh/cluster-manager_ed25519 ysadmin@<NODE_IP>
```

### Migration from the earlier `cluster-ui` design

The current installer removes the obsolete `/etc/sudoers.d/cluster-ui` rule if it exists, but it does **not** automatically delete an existing `cluster-ui` Linux account. After the new `ysadmin` manager-key path has been verified, an old unused account can be removed manually if desired.

## 4. Configure UI authentication

Edit `.env` on the master and change at least:

```dotenv
ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=<LONG_RANDOM_PASSWORD>
```

The SSH paths in `.env.example` already point to the default manager-key locations under `/home/ysadmin/.ssh/`.

The default UI bind is `127.0.0.1:8080`. Access it through an SSH tunnel from an administrator workstation:

```bash
ssh -L 8080:127.0.0.1:8080 ysadmin@<MASTER_IP>
```

Then open `http://127.0.0.1:8080` locally.

If the UI must be directly reachable on the cluster network, change `UI_BIND` in `.env` to the master's intended interface/IP and protect that port with the host firewall.

## 5. Deploy on the master

```bash
docker compose up -d --build
docker compose ps
```

Health check:

```bash
curl http://127.0.0.1:8080/healthz
```

Stop/update:

```bash
docker compose down
git pull
docker compose up -d --build
```

## Current UI operations

Per node the manager can:

- show host CPU, memory and root-disk usage;
- show `rent-node` state, CPU/memory usage and renter account;
- start / stop / restart the container;
- recreate the container while preserving the existing `/src/rent` persistent data;
- show the last 200 container log lines.

The backend also supports `reset-password`, but the initial web UI intentionally does not expose a button for it.

## Security model

1. All normal server administration continues to use the existing `ysadmin` account.
2. The CPU Cluster Manager has its own SSH key pair; the private key exists only on the master.
3. The manager public key is a restricted entry in `ysadmin`'s `authorized_keys`; it cannot open a normal shell.
4. Only the fixed `cluster-node-admin` actions have passwordless sudo for the manager path.
5. Existing human `ysadmin` SSH keys are not replaced or modified.
6. SSH host-key verification is mandatory (`StrictHostKeyChecking=yes`).
7. No Docker TCP API is opened and no Docker socket is mounted into the manager container.
8. The manager SSH private key and `known_hosts` are mounted read-only into the manager container.
9. The manager container is read-only, drops all Linux capabilities, and uses `no-new-privileges`.
10. The UI binds to loopback by default and requires HTTP Basic authentication.

For a later production version, useful next hardening steps are audit logging of every node action and stronger UI authentication (for example, an authenticated reverse proxy or SSO).
