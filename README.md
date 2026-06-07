# DevOps Case Study — MERN Stack + Python ETL Deployment

This repository contains the deployment solution for the DevOps technical case study: containerizing, orchestrating, and shipping a MERN stack application and a Python ETL script to the cloud, with full CI/CD automation, Infrastructure as Code, and observability.

**Live application:** http://3.123.180.61:30931

> The application is deployed on a temporary AWS EC2 instance for evaluation purposes. Infrastructure may be torn down shortly after the review period to avoid ongoing costs (see [Cost Management](#cost-management) below).

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Tech Stack](#tech-stack)
3. [Repository Structure](#repository-structure)
4. [Containerization (Docker)](#containerization-docker)
5. [Local Development](#local-development)
6. [Kubernetes Deployment](#kubernetes-deployment)
7. [Infrastructure as Code (Terraform)](#infrastructure-as-code-terraform)
8. [CI/CD Pipeline (GitHub Actions)](#cicd-pipeline-github-actions)
9. [Monitoring & Logging (Grafana Cloud)](#monitoring--logging-grafana-cloud)
10. [Security Considerations](#security-considerations)
11. [Key Decisions & Challenges](#key-decisions--challenges)
12. [Screenshots](#screenshots)
13. [Cost Management](#cost-management)

---

## Architecture Overview

```
                                   ┌─────────────────────────────┐
                                   │        GitHub Actions        │
                                   │  build → push → deploy       │
                                   └──────────────┬──────────────┘
                                                  │
                          ┌───────────────────────┼───────────────────────┐
                          ▼                       ▼                       ▼
                  ┌───────────────┐      ┌────────────────┐      ┌────────────────┐
                  │  Docker Hub   │      │  Docker Hub    │      │  Docker Hub    │
                  │   backend     │      │   frontend     │      │  python-etl    │
                  └───────┬───────┘      └────────┬───────┘      └────────┬───────┘
                          │                       │                       │
                          └───────────────────────┼───────────────────────┘
                                                  │ kubectl apply / rollout restart
                                                  ▼
 ┌──────────────────────────────────────────────────────────────────────────────────┐
 │  AWS EC2 (t3.small) — single-node k3s cluster, public subnet, Elastic IP         │
 │                                                                                  │
 │   namespace: devops-case                         namespace: monitoring          │
 │   ┌───────────────────────────────────┐          ┌────────────────────────┐     │
 │   │ frontend (nginx + React build)    │◄── NodePort :30931                 │     │
 │   │   └─ reverse proxy → backend      │          │ Grafana Alloy           │     │
 │   │ backend (Express.js, port 5050)   │──────┐   │ kube-state-metrics      │     │
 │   │ python-etl (CronJob, hourly)      │      │   │ node-exporter           │     │
 │   └───────────────────────────────────┘      │   └────────────┬───────────┘     │
 └───────────────────────────────────────────────┼────────────────┼─────────────────┘
                                                  │                │
                                                  ▼                ▼
                                        ┌──────────────────┐  ┌─────────────────────┐
                                        │  MongoDB Atlas   │  │   Grafana Cloud     │
                                        │ (Network Access  │  │ (Prometheus + Loki  │
                                        │  IP whitelisted) │  │  dashboards)        │
                                        └──────────────────┘  └─────────────────────┘
```

The whole stack runs on a **single EC2 instance running [k3s](https://k3s.io/)** — a lightweight, certified Kubernetes distribution. This was a deliberate cost/scope decision explained in [Key Decisions & Challenges](#key-decisions--challenges).

---

## Tech Stack

| Layer | Technology |
|---|---|
| Frontend | React (served via Nginx) |
| Backend | Node.js / Express.js |
| Database | MongoDB Atlas (managed, cloud-hosted) |
| ETL | Python (`requests`) |
| Containerization | Docker, multi-stage builds |
| Orchestration | Kubernetes (k3s) |
| IaC | Terraform (AWS provider) |
| CI/CD | GitHub Actions |
| Image Registry | Docker Hub |
| Cloud Provider | AWS (EC2, VPC, Elastic IP, Security Groups) |
| Monitoring & Logging | Grafana Cloud (Alloy agent → Prometheus + Loki) |

---

## Repository Structure

```
DevOps CASE/
├── mern-project/
│   ├── client/             # React frontend + Dockerfile + nginx.conf (reverse proxy)
│   └── server/             # Express backend + Dockerfile
├── python-project/         # ETL script + Dockerfile + requirements.txt
├── k8s/
│   ├── namespace.yaml
│   ├── backend/            # Deployment + Service (ClusterIP)
│   ├── frontend/           # Deployment + Service (LoadBalancer/NodePort)
│   ├── python/             # CronJob (hourly schedule)
│   └── secret.example.yaml # Template for the ATLAS_URI secret (no real credentials)
├── terraform/              # AWS infrastructure: VPC, subnet, EC2, security group, EIP
├── monitoring/
│   └── values.example.yaml # Grafana Alloy Helm chart values (template, no real credentials)
├── .github/workflows/
│   └── ci-cd.yml           # Build, push, and deploy pipeline
├── docker-compose.yml      # Local multi-container orchestration
└── README.md
```

---

## Containerization (Docker)

Each component has its own Dockerfile, optimized for its runtime:

- **Backend** (`mern-project/server/Dockerfile`): `node:18-alpine` base, production-only `npm install`, exposes port `5050`.
- **Frontend** (`mern-project/client/Dockerfile`): **multi-stage build** — a `node:18-alpine` builder stage runs `npm run build`, and the static output is copied into a lightweight `nginx:alpine` stage. This keeps the final image small (no Node.js runtime or `node_modules` shipped to production) and lets Nginx both serve static files and act as a **reverse proxy** (see [nginx.conf](mern-project/client/nginx.conf)).
- **Python ETL** (`python-project/Dockerfile`): `python:3.11-alpine` base with `requirements.txt`-pinned dependencies.

All images are built and pushed to Docker Hub (`goyash/devops-case-backend`, `goyash/devops-case-frontend`, `goyash/devops-case-python`) by the CI/CD pipeline.

## Local Development

A `docker-compose.yml` is provided to run the full stack locally with one command:

```bash
docker compose up --build
```

This spins up `backend`, `frontend`, and `python-etl` as linked services, with `ATLAS_URI` injected from a local `.env` file (not committed — see `.gitignore`).

---

## Kubernetes Deployment

All workloads run inside a dedicated `devops-case` namespace ([k8s/namespace.yaml](k8s/namespace.yaml)), isolated from system and monitoring components.

| Resource | Purpose |
|---|---|
| `backend/deployment.yaml` + `service.yaml` | Express API, exposed internally via **ClusterIP** on port `5050`. Reads `ATLAS_URI` from a Kubernetes **Secret** (`atlas-secret`), never hardcoded. Has `livenessProbe` / `readinessProbe` on `/healthcheck`. |
| `frontend/deployment.yaml` + `service.yaml` | React + Nginx, exposed externally via a **NodePort** service (port `30931`). |
| `python/cronjob.yaml` | Runs `ETL.py` on a schedule of `0 * * * *` (every hour), satisfying the acceptance criterion. |
| `secret.example.yaml` | Documents the expected secret shape without leaking real credentials. The real secret is created with `kubectl create secret generic atlas-secret --from-env-file=.env -n devops-case`. |

**Rolling updates:** Deployments use `RollingUpdate` strategy with `maxUnavailable: 1, maxSurge: 0`. On a small single-node instance, allowing both old and new pods to run simultaneously (`maxSurge`) risks memory exhaustion; this configuration guarantees the old pod is terminated before the new one starts, trading a few seconds of downtime for stability — an explicit, documented trade-off appropriate for this scale.

**Resource requests/limits** are defined on every container (CPU and memory) so the scheduler can make informed placement decisions and the node doesn't get oversubscribed.

---

## Infrastructure as Code (Terraform)

All AWS infrastructure is defined declaratively under [`terraform/`](terraform/):

- **VPC** (`10.0.0.0/16`) with a public subnet, Internet Gateway, and route table — a minimal but complete network topology.
- **Security Group** restricting:
  - SSH (22) and the Kubernetes API (6443) to the operator's IP only,
  - HTTP/NodePort (80, 30931) open for public access to the application,
  - all egress allowed.
- **EC2 instance** (Amazon Linux 2023, `t3.small`) bootstrapped via `user_data` to install **k3s** automatically on first boot (`curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --tls-san <eip>" sh -`).
- **Elastic IP**, allocated and associated separately (`aws_eip` + `aws_eip_association`) to avoid a circular dependency between the instance's `user_data` (which needs the IP for the TLS SAN) and the EIP association (which needs the instance ID).
- **TLS key pair** generated with the `tls_private_key` / `aws_key_pair` resources and written locally for SSH access — never committed to the repository.

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

Outputs include the public IP, the application URL, and a ready-to-use SSH command.

---

## CI/CD Pipeline (GitHub Actions)

Defined in [`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml), triggered on every push to `main`:

**Job 1 — `build-and-push`**
- Logs into Docker Hub using repository secrets (`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`)
- Builds and pushes all three images (backend, frontend, python-etl) with `docker/build-push-action`

**Job 2 — `deploy`** (runs after build succeeds)
- Configures `kubectl` using a base64-encoded kubeconfig stored in the `KUBECONFIG_DATA` secret
- Applies all Kubernetes manifests (`kubectl apply -f k8s/...`)
- Forces a rolling restart of backend and frontend deployments so the new images are pulled
- Waits for rollout completion with a `300s` timeout — sized generously because the small EC2 instance pulls images over a constrained network/CPU budget

This automates the full path from `git push` to a running, updated application — no manual deployment steps required after the initial infrastructure setup.

---

## Monitoring & Logging (Grafana Cloud)

To satisfy the "logging and alerting" requirement, the cluster runs the **Grafana Kubernetes Monitoring** Helm chart (Grafana Alloy agent), which ships:

- **Metrics** (via Prometheus): pod/container CPU and memory usage (`cadvisor`), Kubernetes object state (`kube-state-metrics`), and host-level metrics (`node-exporter`) — all pushed to Grafana Cloud's managed Prometheus.
- **Logs** (via Loki): live container logs from every pod in the `devops-case` namespace, queryable with LogQL (e.g. `{namespace="devops-case"}`).

A custom dashboard, **"DevOps Case - Cluster Overview"**, visualizes:
- Pod CPU usage over time (`sum(rate(container_cpu_usage_seconds_total{namespace="devops-case"}[5m])) by (pod)`)
- Pod memory usage over time (`sum(container_memory_working_set_bytes{namespace="devops-case"}) by (pod)`)

See [Screenshots](#screenshots) for the live dashboard and log views.

**Why Grafana Cloud instead of self-hosting Prometheus/Grafana?** Self-hosting the full observability stack (Prometheus + Grafana + Loki + storage) would add significant memory pressure on an already resource-constrained single `t3.small` node. Grafana Cloud's free tier offloads storage and the UI to a managed service, while a lightweight agent (Alloy) is the only thing running locally — keeping the cluster lean without sacrificing observability.

A reference template without credentials is provided at [`monitoring/values.example.yaml`](monitoring/values.example.yaml); the real `monitoring/values.yaml` (containing Grafana Cloud API keys) is git-ignored.

---

## Security Considerations

- **No hardcoded secrets**: the MongoDB connection string (`ATLAS_URI`) is injected via a Kubernetes Secret and a local `.env` file — both excluded from version control. `secret.example.yaml` and `values.example.yaml` document the expected shape for reviewers without exposing real credentials.
- **Least-privilege network access**: the Security Group only opens SSH (22) and the Kubernetes API (6443) to the operator's IP address — not `0.0.0.0/0`. Only the application port is publicly reachable.
- **MongoDB Atlas Network Access**: rather than whitelisting `0.0.0.0/0` (which the case brief explicitly asked us to avoid via "pay attention to security"), the cluster's static **Elastic IP** is whitelisted as the single allowed source for the cloud deployment, and the developer's local IP is whitelisted separately for local development. This keeps the database reachable only from known, stable sources.
- **TLS for the Kubernetes API**: the k3s server certificate is issued with the correct `--tls-san` (Subject Alternative Name) matching the public Elastic IP, so `kubectl` connections are properly validated rather than working around certificate errors.
- **Private SSH key never committed**: generated by Terraform, written locally, and excluded via `.gitignore`.

---

## Key Decisions & Challenges

This section documents non-obvious choices made during the deployment — both to explain *why* the code differs from the original case files, and to be transparent about the trade-offs.

### 1. Fixing a hardcoded URL bug in the React frontend
The original frontend components called the backend directly via `http://localhost:5050`. This works only when frontend and backend run on the same host with no reverse proxy — it **breaks immediately** in any containerized or orchestrated environment, where the frontend and backend run in separate containers/pods with their own network namespaces.

**Fix:** the hardcoded URLs were replaced with **relative paths** (`/record`, `/healthcheck`), and an **Nginx reverse proxy** was configured in the frontend container ([nginx.conf](mern-project/client/nginx.conf)) to forward those paths to `http://backend:5050` (the backend's in-cluster Service DNS name). This is a standard pattern for containerized SPAs: the browser only ever talks to one origin (the frontend), and Nginx transparently routes API calls to the backend — avoiding CORS issues and decoupling the frontend from the backend's network location.

This is a deliberate, documented modification to the provided code — made because the original implementation was incompatible with the containerization/orchestration requirements of this case, not as unrelated refactoring.

### 2. MongoDB Atlas Network Access strategy
Initially, opening Atlas's Network Access to `0.0.0.0/0` was considered for simplicity — but the case brief explicitly calls out security as an evaluation criterion. Instead, the EC2 instance's **Elastic IP** (static, survives instance restarts) is whitelisted as the sole allowed source for the deployed application, with the developer's local IP whitelisted separately for local testing. This satisfies connectivity requirements without exposing the database to the entire internet.

### 3. Choosing k3s-on-EC2 over managed Kubernetes (EKS)
A managed Kubernetes service (e.g., AWS EKS) would cost roughly **$0.10/hour for the control plane alone** — about $5+ for a multi-day case study, before counting worker nodes. **k3s** (a certified, lightweight Kubernetes distribution) running on a single EC2 instance provides the same orchestration primitives (Deployments, Services, Secrets, CronJobs, rolling updates) the case requires, at a fraction of the cost (~$0.50–2 total). This was a conscious cost/scope trade-off appropriate for a time-boxed evaluation — in a production setting with sustained load and HA requirements, a managed control plane would be the better choice.

### 4. Resolving a Terraform circular dependency
The EC2 instance's `user_data` script needed the Elastic IP (to set the correct TLS SAN for the k3s API certificate), while the natural way to associate an EIP with an instance requires the instance to exist first — a circular reference. This was resolved by **allocating the EIP as a standalone resource** (`aws_eip`) referenced in `user_data`, and associating it to the instance via a **separate** `aws_eip_association` resource — breaking the cycle while keeping both pieces declarative.

### 5. Memory exhaustion (OOM) on `t3.micro`
The initial, cheapest instance type (`t3.micro`, 1 GB RAM, no swap) became completely unresponsive under the combined load of k3s, three application pods, and CI/CD-driven rolling restarts — `free -m` showed under 50 MB available and SSH sessions hung indefinitely. 

**Resolution:** the instance was stopped, resized to `t3.small` (2 GB RAM) via `aws ec2 modify-instance-attribute`, and a 2 GB swap file was added as a safety margin. Additionally, `RollingUpdate` strategy was tuned (`maxSurge: 0`) and explicit resource `requests`/`limits` were added to every container — preventing simultaneous old+new pod memory spikes during deployments. This is documented as a real constraint encountered when right-sizing infrastructure for a stateful, multi-component workload on a budget.

### 6. LoadBalancer service stuck in `<pending>`
k3s ships with a lightweight built-in load balancer (`klipper-lb` / ServiceLB) that, in this networking setup, did not assign an external IP to the frontend's `LoadBalancer` service. Rather than spending limited time debugging a non-essential component, the service was switched to **NodePort** (port `30931`), and that port was opened in the AWS Security Group — a pragmatic, equally valid way to expose a service externally on a single-node cluster.

### 7. Stale Docker images causing CORS errors
After fixing the hardcoded URL issue (Decision #1), the application still showed CORS errors in the browser — because the **Docker images on Docker Hub had been built before the fix** was committed. Rebuilding and re-pushing the frontend image, followed by `kubectl rollout restart deployment/frontend`, resolved it. This highlighted the importance of the CI/CD pipeline (which now rebuilds and redeploys automatically on every push, eliminating this class of issue going forward).

---

## Screenshots

> See the [`screenshots/`](screenshots/) folder for full-resolution images.

| Screenshot | Description |
|---|---|
| `api-status.png` | The frontend's "API Status" page, loaded from the live public URL (`3.123.180.61:30931`), showing a live response from the backend's `/healthcheck` endpoint — proof that frontend, backend, and their network path are all working in production |
| `create-record.png` | The "Create Record" form, served at `3.123.180.61:30931/create` — frontend routing and static asset serving working correctly through Nginx |
| `record-list.png` | The "Record List" page at `3.123.180.61:30931/records`, confirming the backend's MongoDB-backed `/record` endpoint responds successfully |
| `kubectl-pods.png` | `kubectl get pods -n devops-case` showing the backend/frontend pods `Running` and three hourly `python-etl` CronJob runs `Completed` — direct proof of the "ETL runs every hour" acceptance criterion |
| `cicd-pipeline-build-and-push.png` | The `build-and-push` job of the GitHub Actions pipeline — all three Docker images built and pushed successfully |
| `cicd-pipeline-deploy.png` | The `deploy` job — kubeconfig configured and manifests applied/rolled out to the live Kubernetes cluster |
| `grafana-dashboard.png` | The "DevOps Case - Cluster Overview" Grafana Cloud dashboard showing live CPU and memory metrics for every pod |
| `grafana-logs.png` | Live container logs from the `devops-case` namespace queried via Loki/LogQL, including Kubernetes health-check traffic |

---

## Cost Management

This deployment intentionally favors **low-cost, right-sized infrastructure** appropriate for a short-lived technical evaluation:

- A single `t3.small` EC2 instance running k3s (~$0.0208/hour) instead of a managed Kubernetes control plane
- An AWS Budget alert configured to notify automatically if spend exceeds a low threshold
- Infrastructure is provisioned with `terraform apply` and can be fully torn down with a single `terraform destroy` — leaving no lingering billable resources once the evaluation is complete

```bash
cd terraform
terraform destroy
```
