# CPU Cluster Manager

A small SSH-based web UI for managing one `rent-node` Docker container per compute node.

The repository contains both:

- `manager/`: FastAPI management UI, intended to run as a Docker container on the Cluster 1 master node.
- `node/`: the compute-node management wrapper plus the existing `rent` container image/lifecycle scripts.

The manager **does not mount `/var/run/docker.sock`** and **does not expose the Docker remote API**. It SSHes to each compute node as the restricted `cluster-ui` account and can only sudo a fixed wrapper command.

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
│   ├── install-node.sh
│   └── rent-image/          # existing rent container code
└── scripts/
    └── prepare-master-ssh.sh
```

## 1. Clone on the Cluster 1 master

```bash
git clone <YOUR_GITHUB_REPOSITORY_URL>
cd cpu-cluster-manager
cp .env.example .env
cp config/nodes.example.yaml config/nodes.yaml
```

Edit `config/nodes.yaml` with the actual Cluster 1 compute-node addresses.

## 2. Prepare the master SSH key

The manager container uses a dedicated SSH key. Generate the key and build a strict `known_hosts` file from `config/nodes.yaml`:

```bash
./scripts/prepare-master-ssh.sh config/nodes.yaml
```

The default key paths are:

```text
~/.ssh/cluster-ui_ed25519
~/.ssh/cluster-ui_ed25519.pub
~/.ssh/cluster-ui_known_hosts
```

Update `.env` if the master-side paths differ.

## 3. Install node-side management access

On each compute node, copy or clone this repository and run:

```bash
sudo ./node/install-node.sh /path/to/cluster-ui_ed25519.pub
```

This installs:

- the existing rent scripts under `/src/rent/image/`
- `/usr/local/sbin/cluster-node-admin`
- a key-only `cluster-ui` account
- sudo rules that permit only the fixed node-management actions

The UI intentionally does **not** expose the destructive `rentctl.sh reset` or `setup` commands.

Verify from the master:

```bash
ssh -i ~/.ssh/cluster-ui_ed25519 cluster-ui@<NODE_IP> \
  sudo /usr/local/sbin/cluster-node-admin summary
```

## 4. Configure UI authentication

Edit `.env` and change at least:

```dotenv
ADMIN_USERNAME=clusteradmin
ADMIN_PASSWORD=<LONG_RANDOM_PASSWORD>
```

The default bind is `127.0.0.1:8080`. This is deliberate. Access it through an SSH tunnel:

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

- show host CPU, memory and root-disk usage
- show `rent-node` state, CPU/memory usage and renter account
- start / stop / restart the container
- recreate the container while preserving the existing `/src/rent` persistent data
- show the last 200 container log lines

The backend also supports `reset-password`, but the initial web UI intentionally does not expose a button for it.

## Security model

1. No Docker TCP API is opened.
2. No Docker socket is mounted into the manager container.
3. SSH host-key verification is mandatory (`StrictHostKeyChecking=yes`).
4. The manager SSH key is mounted read-only.
5. The node-side `cluster-ui` account has no password and only a narrow sudo allowlist.
6. The manager container is read-only, drops all Linux capabilities, and uses `no-new-privileges`.
7. The UI binds to loopback by default and requires HTTP Basic authentication.

For a later production version, the next hardening step should be SSO/reverse-proxy authentication plus audit logging of every node action.
