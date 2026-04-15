# Multi-Environment EKS GitOps Platform

> A production-grade Kubernetes platform on AWS EKS with full GitOps automation, multi-environment promotion, service mesh, and complete observability — built entirely with Infrastructure as Code.

---

## What This Project Builds

A complete DevOps platform that mirrors how modern engineering teams deploy software at scale. Every code change flows through an automated pipeline — tested, scanned, containerised, and deployed to Kubernetes without any manual steps. The infrastructure itself is version-controlled and reproducible from a single command.

---

## Architecture

```
Developer pushes code
        │
        ▼
   GitHub Repository
        │
        ▼
GitHub Actions CI Pipeline
   ├── Unit tests + coverage
   ├── SonarQube code quality scan
   ├── Docker build (linux/amd64)
   ├── Trivy vulnerability scan (blocks on CRITICAL)
   └── Push image to Amazon ECR
        │
        ▼
  Update image tag in k8s/overlays/{env}/
        │
        ▼
     ArgoCD (GitOps)
   Detects manifest change in GitHub
        │
        ├── Dev → auto-sync, no approval
        ├── Staging → auto-sync, no approval
        └── Prod → manual approval gate
        │
        ▼
   Amazon EKS Fargate
   ├── Istio service mesh (mTLS, traffic splitting)
   ├── Blue/Green + Canary deployments
   └── Horizontal Pod Autoscaler
        │
        ▼
Application Load Balancer → Users
        │
        ▼
Prometheus + Grafana + Loki + Tempo
   (Metrics, Logs, Traces, Dashboards)
```

---

## Infrastructure Overview

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Cloud | AWS ap-south-1 | Mumbai region |
| IaC | Terraform + S3 backend | All infrastructure as code |
| Container Orchestration | Amazon EKS 1.32 | Managed Kubernetes |
| Container Registry | Amazon ECR | Private Docker image storage |
| Networking | VPC + private/public subnets | Isolated network across 2 AZs |
| Load Balancing | AWS Load Balancer Controller | Kubernetes-native ALB provisioning |
| GitOps | ArgoCD | Git as single source of truth |
| CI/CD | GitHub Actions | Automated build, test, deploy |
| Service Mesh | Istio | mTLS, traffic management, observability |
| Secrets | AWS Secrets Manager + CSI Driver | No secrets in Git |
| Autoscaling | Cluster Autoscaler + HPA | Auto-scale nodes and pods |
| TLS | Cert-Manager + Let's Encrypt | Automatic certificate management |
| DNS | External-DNS + Route 53 | Auto-create DNS from Ingress |
| Metrics | Prometheus + Grafana | Real-time dashboards and alerts |
| Logs | Loki + Promtail | Centralised log aggregation |
| Traces | Tempo | Distributed request tracing |
| Policy | OPA Gatekeeper | Enforce Kubernetes security policies |
| Image Scanning | Trivy | Block deployments with CRITICAL CVEs |

---

## Multi-Environment Promotion Flow

```
feature/* branch
      │
      ▼ PR opened
   GitHub Actions CI
   (tests + scan + build)
      │
      ▼ merged to develop
   Auto-deploy → DEV
   (ArgoCD syncs immediately)
      │
      ▼ PR to main
   Auto-deploy → STAGING
   (ArgoCD syncs immediately)
      │
      ▼ Manual approval in GitHub Environments
   Deploy → PRODUCTION
   (ArgoCD syncs after approval)
```

Each environment is a completely separate EKS namespace with its own resource limits, replica counts, and configuration. Prod uses ON_DEMAND nodes. Dev and staging use SPOT instances to reduce cost.

---

## Project Structure

```
eks-gitops-platform/
│
├── terraform/                          Infrastructure as Code
│   ├── environments/
│   │   ├── dev/
│   │   │   ├── main.tf                 Dev environment — calls vpc + eks modules
│   │   │   └── backend.tf              S3 remote state + DynamoDB lock
│   │   ├── staging/
│   │   │   ├── main.tf
│   │   │   └── backend.tf
│   │   └── prod/
│   │       ├── main.tf
│   │       └── backend.tf
│   └── modules/
│       ├── vpc/
│       │   ├── main.tf                 VPC, subnets, NAT Gateway, route tables
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── eks/
│           ├── main.tf                 EKS cluster, node groups, addons, IRSA
│           ├── variables.tf
│           └── outputs.tf
│
├── k8s/                                Kubernetes manifests
│   ├── base/
│   │   ├── deployment.yaml             Base deployment (nginx, 2 replicas)
│   │   ├── service.yaml                ClusterIP service
│   │   └── kustomization.yaml          Kustomize base
│   └── overlays/
│       ├── dev/
│       │   └── kustomization.yaml      1 replica, dev namespace
│       ├── staging/
│       │   └── kustomization.yaml      2 replicas, staging namespace
│       └── prod/
│           └── kustomization.yaml      3 replicas, prod namespace
│
├── argocd/                             ArgoCD GitOps configuration
│   ├── apps/
│   │   ├── root.yaml                   App-of-Apps root application
│   │   ├── dev.yaml                    Dev ArgoCD Application
│   │   ├── staging.yaml                Staging ArgoCD Application
│   │   └── prod.yaml                   Prod ArgoCD Application
│   └── projects/
│       └── eks-platform.yaml           ArgoCD Project with RBAC
│
├── helm-charts/
│   └── app/
│       ├── Chart.yaml
│       ├── values.yaml                 Default values
│       ├── values-dev.yaml             Dev overrides
│       ├── values-staging.yaml         Staging overrides
│       └── values-prod.yaml            Prod overrides
│
├── monitoring/
│   ├── prometheus/
│   │   ├── values.yaml                 kube-prometheus-stack Helm values
│   │   └── alerts.yaml                 Custom PrometheusRule alerts
│   ├── grafana/
│   │   └── dashboards/                 Exported dashboard JSON files
│   └── loki/
│       └── values.yaml                 Loki stack Helm values
│
├── .github/
│   └── workflows/
│       ├── ci.yml                      Build, test, scan, push image
│       ├── cd-dev.yml                  Auto-deploy to dev on develop push
│       ├── cd-staging.yml              Auto-deploy to staging on main push
│       └── cd-prod.yml                 Manual-gate deploy to prod
│
├── scripts/
│   ├── bootstrap.sh                    One-click full platform setup
│   └── destroy.sh                      Full teardown script
│
├── .gitignore                          Excludes .terraform/, tfstate, secrets
├── README.md                           This file — project overview
└── DEPLOYMENT.md                       Step-by-step deployment guide
```

---

## Key Design Decisions

**GitOps over push-based CI/CD** — ArgoCD continuously reconciles cluster state with Git. If someone manually changes a Kubernetes resource, ArgoCD automatically reverts it within minutes. Git is the single source of truth for what runs in the cluster.

**Kustomize over Helm for manifests** — Base manifests are shared across all environments. Each overlay only specifies what is different (replica count, resource limits, image tag). This keeps environment config minimal and auditable.

**IRSA over node IAM roles** — Instead of giving broad AWS permissions to EC2 nodes, each Kubernetes service account gets its own IAM role with minimum required permissions via IAM Roles for Service Accounts. The EBS CSI driver only has EBS permissions, not full EC2 access.

**SPOT instances for non-prod** — Dev and staging node groups use EC2 SPOT instances which cost 60–90% less than ON_DEMAND. Cluster Autoscaler handles interruptions automatically. Production uses ON_DEMAND for reliability.

**Separate Terraform state per environment** — Each environment has its own S3 key and DynamoDB lock entry. A failed prod deployment cannot corrupt dev state and vice versa.

**Trivy blocks on CRITICAL** — The CI pipeline will not push an image to ECR if Trivy finds any CRITICAL severity CVE. This prevents vulnerable images from ever reaching the cluster.

---

## Cost Estimate

| Resource | Dev/day | Prod/day |
|----------|---------|----------|
| EKS control plane | ₹83 | ₹83 |
| EC2 nodes (SPOT t3.medium × 2) | ₹40 | — |
| EC2 nodes (ON_DEMAND t3.medium × 3) | — | ₹180 |
| NAT Gateway | ₹90 | ₹90 × 3 AZs |
| ALB | ₹16 | ₹16 |
| ECR storage | Negligible | Negligible |

> Run `terraform destroy` on dev/staging when not in use. EKS control plane charges even when idle.

---

## Lessons Learned

**IRSA is mandatory for EBS CSI** — The EBS CSI driver crashes with `UnauthorizedOperation` if the pod runs under the node IAM role instead of a dedicated service account role. Always create the IRSA with `eksctl create iamserviceaccount` before expecting EBS volumes to work.

**Terraform state checksum drift** — If a `terraform apply` is interrupted mid-write, S3 gets the new state but DynamoDB retains the old checksum. Fix by updating the DynamoDB `Digest` item to match the S3 MD5. Never delete and recreate the state file unless absolutely necessary.

**`.terraform/` in git history** — Provider binaries are 600MB+. Once committed to git history they remain even after `.gitignore` is added. Use `git filter-branch` or `git filter-repo` to rewrite history and remove them before the first push.

**ArgoCD ApplicationSet CRD annotation limit** — Installing ArgoCD via `kubectl apply` hits a 262KB annotation limit on the ApplicationSet CRD. The `applicationset-controller` crashes as a result. Fix by removing the `last-applied-configuration` annotation from the CRD and restarting the controller.

**EKS addon version deprecation** — AWS periodically deprecates Kubernetes versions. Always check supported versions with `aws eks describe-cluster-versions` before deploying. Terraform will fail at the cluster creation step if the version is unsupported.

**KMS alias and CloudWatch log groups persist after destroy** — When you delete an EKS cluster manually (not via Terraform), the KMS alias and CloudWatch log group created by the EKS Terraform module are not cleaned up. On the next `terraform apply` these cause `AlreadyExistsException`. Delete them manually with `aws kms delete-alias` and `aws logs delete-log-group`.

---

## Tech Stack

`AWS EKS 1.32` · `Terraform` · `ArgoCD` · `GitHub Actions` · `Helm` · `Kustomize` · `Istio` · `Prometheus` · `Grafana` · `Loki` · `Tempo` · `OPA Gatekeeper` · `Trivy` · `Cert-Manager` · `External-DNS` · `AWS Load Balancer Controller` · `eksctl` · `kubectl` · `k9s`

---

## Author

**ManojKumar-Devops** · [github.com/ManojKumar-Devops](https://github.com/ManojKumar-Devops)
