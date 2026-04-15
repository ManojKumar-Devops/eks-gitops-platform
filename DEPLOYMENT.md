# Deployment Guide

Complete step-by-step instructions to deploy and destroy the EKS GitOps Platform. Follow phases in order — each phase depends on the previous one being complete.

---

## Prerequisites

Install these tools before starting:

```bash
# Homebrew (Mac)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Core tools
brew install terraform kubectl helm awscli eksctl k9s

# Verify installs
terraform --version    # need 1.5+
kubectl version --client
helm version
aws --version
eksctl version
```

AWS account requirements:
- IAM user with `AdministratorAccess` (never use root account)
- Region: `ap-south-1` (Mumbai)

GitHub requirements:
- Classic Personal Access Token with `repo`, `workflow`, `admin:repo_hook` scopes
- Create at: `github.com/settings/tokens`

---

## Phase 1 — AWS and Git Setup

### Step 1 — Configure AWS CLI

```bash
aws configure
# AWS Access Key ID:     AKIA...
# AWS Secret Access Key: xxxxxxx
# Default region:        ap-south-1
# Output format:         json
```

Verify you are using an IAM user (not root):

```bash
aws sts get-caller-identity
# "Arn" must show :user/... NOT :root
```

### Step 2 — Create GitHub repository

Go to `github.com/new`:
```
Name:       eks-gitops-platform
Visibility: Public
Init:       NO (leave all checkboxes unchecked)
```

### Step 3 — Clone and initialise local repo

```bash
mkdir ~/eks-gitops-platform
cd ~/eks-gitops-platform
git init
git remote add origin https://github.com/YOUR_USERNAME/eks-gitops-platform.git
git branch -M main
```

### Step 4 — Store GitHub token in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name github-token \
  --secret-string "ghp_YOUR_TOKEN_HERE" \
  --region ap-south-1
```

### Step 5 — Store token in git credentials (avoids repeated prompts)

```bash
git config --global credential.helper store
echo "https://YOUR_USERNAME:ghp_YOUR_TOKEN@github.com" > ~/.git-credentials
chmod 600 ~/.git-credentials
```

---

## Phase 2 — Terraform State Backend

Run once per AWS account:

### Step 1 — Create S3 bucket for Terraform state

```bash
aws s3 mb s3://eks-platform-tfstate-YOUR_ACCOUNT_ID --region ap-south-1
```

### Step 2 — Enable versioning

```bash
aws s3api put-bucket-versioning \
  --bucket eks-platform-tfstate-YOUR_ACCOUNT_ID \
  --versioning-configuration Status=Enabled
```

### Step 3 — Create DynamoDB table for state locking

```bash
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-south-1
```

---

## Phase 3 — Deploy Infrastructure with Terraform

### Step 1 — Deploy VPC

```bash
cd ~/eks-gitops-platform/terraform/environments/dev
terraform init
terraform plan
terraform apply -auto-approve
```

Expected output:
```
Apply complete! Resources: 23 added, 0 changed, 0 destroyed.
Outputs:
vpc_id = "vpc-xxxxxxxxxxxx"
```

### Step 2 — Deploy EKS cluster

Update `main.tf` to include the EKS module (see project structure), then:

```bash
terraform init -upgrade
terraform plan
terraform apply -auto-approve
```

This takes 15–20 minutes. EKS cluster creation is slow — do not cancel.

Expected output:
```
Apply complete! Resources: 11 added, 0 changed, 0 destroyed.
Outputs:
cluster_endpoint = "https://XXXX.gr7.ap-south-1.eks.amazonaws.com"
cluster_name     = "eks-platform-dev"
```

### Step 3 — Connect kubectl to the cluster

```bash
aws eks update-kubeconfig \
  --name eks-platform-dev \
  --region ap-south-1

kubectl get nodes
```

Expected:
```
NAME                                        STATUS   ROLES    AGE   VERSION
ip-10-0-2-xx.ap-south-1.compute.internal   Ready    <none>   2m    v1.32.x
ip-10-0-3-xx.ap-south-1.compute.internal   Ready    <none>   2m    v1.32.x
```

### Step 4 — Fix EBS CSI driver IAM permissions

The EBS CSI controller needs its own IAM role (IRSA):

```bash
eksctl create iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster eks-platform-dev \
  --region ap-south-1 \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
  --approve \
  --override-existing-serviceaccounts

kubectl rollout restart deployment ebs-csi-controller -n kube-system
kubectl get pods -n kube-system
```

All pods must show `Running` before proceeding.

---

## Phase 4 — EKS Cluster Bootstrap

### Step 1 — Add Helm repos

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo add jetstack https://charts.jetstack.io
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### Step 2 — Install AWS Load Balancer Controller

```bash
eksctl create iamserviceaccount \
  --cluster eks-platform-dev \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --attach-policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess \
  --approve \
  --region ap-south-1 \
  --override-existing-serviceaccounts

VPC_ID=$(aws eks describe-cluster \
  --name eks-platform-dev \
  --region ap-south-1 \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=eks-platform-dev \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=ap-south-1 \
  --set vpcId=$VPC_ID

kubectl get pods -n kube-system | grep load-balancer
```

### Step 3 — Install Cert-Manager

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true

kubectl get pods -n cert-manager
```

### Step 4 — Install Metrics Server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl top nodes
```

---

## Phase 5 — ArgoCD GitOps Setup

### Step 1 — Install ArgoCD

```bash
kubectl create namespace argocd

kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n argocd --timeout=300s
```

### Step 2 — Fix ApplicationSet CRD annotation issue

```bash
kubectl annotate crd applicationsets.argoproj.io \
  kubectl.kubernetes.io/last-applied-configuration- \
  --overwrite 2>/dev/null || true

kubectl rollout restart deployment \
  argocd-applicationset-controller -n argocd

kubectl get pods -n argocd
```

All ArgoCD pods must show `Running`.

### Step 3 — Access ArgoCD UI

```bash
# Start port-forward (keep this running)
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Open `https://localhost:8080` in browser.
- Click **Advanced** → **Proceed to localhost**
- Login: `admin` / (password from above)

### Step 4 — Create Kubernetes manifests

```bash
mkdir -p ~/eks-gitops-platform/k8s/base
mkdir -p ~/eks-gitops-platform/k8s/overlays/dev
mkdir -p ~/eks-gitops-platform/k8s/overlays/staging
mkdir -p ~/eks-gitops-platform/k8s/overlays/prod
```

Create `k8s/base/deployment.yaml`, `k8s/base/service.yaml`, and `k8s/base/kustomization.yaml` as shown in the project structure.

Create environment overlays in `k8s/overlays/{dev,staging,prod}/kustomization.yaml`.

### Step 5 — Push manifests to GitHub

```bash
cd ~/eks-gitops-platform
git add k8s/
git commit -m "feat: add kubernetes manifests and environment overlays"
git push origin main
```

### Step 6 — Create ArgoCD Application

```bash
kubectl create namespace app-dev

cat << 'EOF' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/YOUR_USERNAME/eks-gitops-platform.git
    targetRevision: HEAD
    path: k8s/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: app-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
```

### Step 7 — Verify GitOps is working

```bash
kubectl get applications -n argocd
kubectl get pods -n app-dev
```

Expected:
```
NAME      SYNC STATUS   HEALTH STATUS
app-dev   Synced        Healthy
```

---

## Phase 6 — GitHub Actions CI/CD

### Step 1 — Add GitHub Secrets

Go to your GitHub repo → Settings → Secrets and variables → Actions → New repository secret:

```
AWS_ACCESS_KEY_ID      → your IAM user access key
AWS_SECRET_ACCESS_KEY  → your IAM user secret key
```

### Step 2 — Create workflows

Create `.github/workflows/ci.yml` and `.github/workflows/cd-dev.yml` as shown in the project structure.

### Step 3 — Test pipeline

```bash
echo "# test" >> app/README.md
git add .
git commit -m "test: trigger CI pipeline"
git push origin main
```

Go to GitHub → Actions tab → watch the pipeline run.

---

## Phase 7 — Observability Stack

### Step 1 — Install Prometheus + Grafana

```bash
helm install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=admin123 \
  --set prometheus.prometheusSpec.retention=15d

kubectl get pods -n monitoring
```

### Step 2 — Access Grafana

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana \
  -n monitoring 3000:80 &
```

Open `http://localhost:3000` — login with `admin` / `admin123`.

Import dashboard IDs:
- `15760` — Kubernetes cluster overview
- `13770` — EKS cluster monitoring
- `11454` — Node exporter full

### Step 3 — Install Loki for logs

```bash
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set grafana.enabled=false \
  --set promtail.enabled=true

kubectl get pods -n monitoring | grep loki
```

---

## Phase 8 — Test End-to-End GitOps Flow

```bash
sed -i '' 's/replicas: 2/replicas: 3/' \
  ~/eks-gitops-platform/k8s/base/deployment.yaml

git add k8s/base/deployment.yaml
git commit -m "feat: scale app to 3 replicas"
git push origin main
```

Watch ArgoCD detect the change and sync automatically:

```bash
kubectl get applications -n argocd -w
kubectl get pods -n app-dev -w
```

Within 60 seconds ArgoCD will deploy 3 pods with zero manual intervention.

---

## Phase 9 — Destroy and Cleanup

> **⚠ Critical: Always destroy in this exact order.** Destroying Terraform before removing Kubernetes resources leaves orphaned ALBs attached to the VPC, which blocks VPC deletion and leaves resources charging your account.

### Destroy order

```
ArgoCD apps → Helm releases → ArgoCD → IRSA roles → Terraform destroy → AWS resources → State backend
```

### Step 1 — Delete ArgoCD applications

Removes all Kubernetes workloads ArgoCD manages:

```bash
kubectl delete application app-dev -n argocd 2>/dev/null || true
kubectl get pods -n app-dev 2>/dev/null || echo "namespace cleaned up"
```

### Step 2 — Uninstall Helm releases

The Load Balancer Controller must be uninstalled first — it owns the ALB. Removing it deletes the ALB from AWS before Terraform destroys the VPC.

```bash
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
helm uninstall loki -n monitoring 2>/dev/null || true
helm uninstall cert-manager -n cert-manager 2>/dev/null || true
helm uninstall cluster-autoscaler -n kube-system 2>/dev/null || true
```

Verify ALB is fully deleted from AWS before proceeding — this is critical:

```bash
aws elbv2 describe-load-balancers \
  --region ap-south-1 \
  --query 'LoadBalancers[?contains(LoadBalancerName, `eks`)].LoadBalancerName' \
  --output table
```

Wait until this returns empty. The ALB must be gone before running Terraform destroy.

### Step 3 — Uninstall ArgoCD and delete namespaces

```bash
kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  2>/dev/null || true

kubectl delete namespace argocd    2>/dev/null || true
kubectl delete namespace app-dev   2>/dev/null || true
kubectl delete namespace monitoring 2>/dev/null || true
kubectl delete namespace cert-manager 2>/dev/null || true
```

Verify only system namespaces remain:

```bash
kubectl get namespaces
```

Should show only: `default`, `kube-system`, `kube-public`, `kube-node-lease`

### Step 4 — Delete IRSA service accounts

eksctl created IAM roles for EBS CSI and Load Balancer Controller. Delete them before Terraform to avoid IAM conflicts:

```bash
eksctl delete iamserviceaccount \
  --name ebs-csi-controller-sa \
  --namespace kube-system \
  --cluster eks-platform-dev \
  --region ap-south-1 2>/dev/null || true

eksctl delete iamserviceaccount \
  --name aws-load-balancer-controller \
  --namespace kube-system \
  --cluster eks-platform-dev \
  --region ap-south-1 2>/dev/null || true
```

Verify IAM roles are removed:

```bash
aws iam list-roles \
  --query 'Roles[?contains(RoleName, `eks-platform-dev`)].RoleName' \
  --output table
```

### Step 5 — Terraform destroy

Destroys the EKS cluster, node groups, VPC, subnets, NAT Gateway, Internet Gateway, security groups, KMS key, and CloudWatch log group:

```bash
cd ~/eks-gitops-platform/terraform/environments/dev
terraform destroy -auto-approve
```

This takes 15–20 minutes. Resources are destroyed in this order:
- EKS managed node groups (~5 min)
- EKS cluster (~3 min)
- EKS addons (coredns, vpc-cni, kube-proxy, ebs-csi)
- Security groups
- Subnets
- NAT Gateway (~2 min)
- Internet Gateway
- VPC
- IAM roles
- KMS key + alias
- CloudWatch log group

Expected final output:
```
Destroy complete! Resources: 34 destroyed.
```

### Step 6 — Delete remaining AWS resources

These are created outside Terraform and must be deleted manually:

```bash
# Delete ECR repository and all images
aws ecr batch-delete-image \
  --repository-name eks-platform-app \
  --region ap-south-1 \
  --image-ids imageTag=latest 2>/dev/null || true

aws ecr delete-repository \
  --repository-name eks-platform-app \
  --force \
  --region ap-south-1 2>/dev/null || true

# Delete GitHub token secret
aws secretsmanager delete-secret \
  --secret-id github-token \
  --force-delete-without-recovery \
  --region ap-south-1 2>/dev/null || true

# Delete CloudWatch log group if it remains
aws logs delete-log-group \
  --log-group-name /aws/eks/eks-platform-dev/cluster \
  --region ap-south-1 2>/dev/null || true

# Delete KMS alias if it remains
aws kms delete-alias \
  --alias-name alias/eks/eks-platform-dev \
  --region ap-south-1 2>/dev/null || true
```

### Step 7 — Handle leftover VPC resources (if Terraform missed them)

If Terraform destroy left a VPC or NAT Gateway, clean them up manually:

```bash
# Check for leftover resources
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=*eks*" \
  --region ap-south-1 \
  --query 'Vpcs[*].{VpcId:VpcId,Name:Tags[?Key==`Name`].Value|[0]}'

aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --region ap-south-1 \
  --query 'NatGateways[*].{Id:NatGatewayId,VPC:VpcId}'
```

If resources exist, delete in this order:

```bash
# 1. Delete NAT Gateway
aws ec2 delete-nat-gateway \
  --nat-gateway-id nat-XXXXXXXXXXXXXXXXX \
  --region ap-south-1

aws ec2 wait nat-gateway-deleted \
  --nat-gateway-ids nat-XXXXXXXXXXXXXXXXX \
  --region ap-south-1 && echo "NAT Gateway deleted"

# 2. Release Elastic IP
ALLOC_ID=$(aws ec2 describe-addresses \
  --region ap-south-1 \
  --query 'Addresses[?AssociationId==null].AllocationId' \
  --output text)
aws ec2 release-address --allocation-id $ALLOC_ID --region ap-south-1

# 3. Delete subnets
for subnet in $(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-XXXXXXXXXXXXXXXXX" \
  --region ap-south-1 \
  --query 'Subnets[*].SubnetId' --output text); do
  aws ec2 delete-subnet --subnet-id $subnet --region ap-south-1
done

# 4. Detach and delete Internet Gateway
IGW=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=vpc-XXXXXXXXXXXXXXXXX" \
  --region ap-south-1 \
  --query 'InternetGateways[0].InternetGatewayId' --output text)
aws ec2 detach-internet-gateway \
  --internet-gateway-id $IGW \
  --vpc-id vpc-XXXXXXXXXXXXXXXXX --region ap-south-1
aws ec2 delete-internet-gateway \
  --internet-gateway-id $IGW --region ap-south-1

# 5. Remove security group rules (handles cross-reference dependency)
for sg in $(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=vpc-XXXXXXXXXXXXXXXXX" \
  --region ap-south-1 \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
  --output text); do
  aws ec2 revoke-security-group-ingress --group-id $sg \
    --ip-permissions "$(aws ec2 describe-security-groups \
      --group-ids $sg --region ap-south-1 \
      --query 'SecurityGroups[0].IpPermissions' --output json)" \
    --region ap-south-1 2>/dev/null || true
  aws ec2 revoke-security-group-egress --group-id $sg \
    --ip-permissions "$(aws ec2 describe-security-groups \
      --group-ids $sg --region ap-south-1 \
      --query 'SecurityGroups[0].IpPermissionsEgress' --output json)" \
    --region ap-south-1 2>/dev/null || true
  aws ec2 delete-security-group --group-id $sg --region ap-south-1
done

# 6. Delete route tables (non-main)
for rt in $(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=vpc-XXXXXXXXXXXXXXXXX" \
  --region ap-south-1 \
  --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' \
  --output text); do
  aws ec2 delete-route-table --route-table-id $rt --region ap-south-1
done

# 7. Finally delete the VPC
aws ec2 delete-vpc \
  --vpc-id vpc-XXXXXXXXXXXXXXXXX \
  --region ap-south-1 && echo "VPC deleted"
```

### Step 8 — Delete Terraform state backend

> Skip this step if you plan to redeploy later. The S3 bucket and DynamoDB table cost less than ₹1/month and can be reused.

```bash
# Delete all versioned objects in S3 (versioning prevents simple deletion)
aws s3api delete-objects \
  --bucket eks-platform-tfstate-YOUR_ACCOUNT_ID \
  --delete "$(aws s3api list-object-versions \
    --bucket eks-platform-tfstate-YOUR_ACCOUNT_ID \
    --region ap-south-1 \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json)" \
  --region ap-south-1 2>/dev/null || true

# Delete all delete markers
aws s3api delete-objects \
  --bucket eks-platform-tfstate-YOUR_ACCOUNT_ID \
  --delete "$(aws s3api list-object-versions \
    --bucket eks-platform-tfstate-YOUR_ACCOUNT_ID \
    --region ap-south-1 \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json)" \
  --region ap-south-1 2>/dev/null || true

# Now delete the bucket
aws s3 rb \
  s3://eks-platform-tfstate-YOUR_ACCOUNT_ID \
  --region ap-south-1

# Delete DynamoDB lock table
aws dynamodb delete-table \
  --table-name terraform-state-lock \
  --region ap-south-1
```

### Step 9 — Clean up local kubeconfig

```bash
kubectl config delete-context \
  arn:aws:eks:ap-south-1:YOUR_ACCOUNT_ID:cluster/eks-platform-dev \
  2>/dev/null || true

kubectl config delete-cluster \
  arn:aws:eks:ap-south-1:YOUR_ACCOUNT_ID:cluster/eks-platform-dev \
  2>/dev/null || true

kubectl config get-contexts
```

`eks-platform-dev` should no longer appear.

### Step 10 — Final verification — confirm zero AWS charges

Run this full check — every section must return empty:

```bash
echo "=== EKS clusters ===" && \
aws eks list-clusters --region ap-south-1

echo "=== VPCs ===" && \
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=*eks*" \
  --region ap-south-1 \
  --query 'Vpcs[*].VpcId'

echo "=== NAT Gateways ===" && \
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --region ap-south-1 \
  --query 'NatGateways[*].NatGatewayId'

echo "=== Load Balancers ===" && \
aws elbv2 describe-load-balancers \
  --region ap-south-1 \
  --query 'LoadBalancers[?contains(LoadBalancerName,`eks`)].LoadBalancerName'

echo "=== Elastic IPs ===" && \
aws ec2 describe-addresses \
  --region ap-south-1 \
  --query 'Addresses[*].PublicIp'

echo "=== ECR repos ===" && \
aws ecr describe-repositories \
  --region ap-south-1 \
  --query 'repositories[*].repositoryName' 2>/dev/null || echo "none"

echo "=== S3 state bucket ===" && \
aws s3 ls | grep eks-platform || echo "deleted"

echo "=== DynamoDB ===" && \
aws dynamodb list-tables \
  --region ap-south-1 \
  --query 'TableNames[?contains(@, `terraform`)]'
```

All sections returning `[]` or empty confirms your AWS account is completely clean with zero ongoing charges.

### Resources destroyed — complete list

| Resource | Destroyed by |
|----------|-------------|
| ArgoCD applications | `kubectl delete application` |
| App pods + services | ArgoCD cleanup |
| Helm releases (ALB, Prometheus, Loki, Cert-Manager) | `helm uninstall` |
| IRSA IAM roles (EBS CSI, ALB Controller) | `eksctl delete iamserviceaccount` |
| EKS managed node groups | `terraform destroy` |
| EKS cluster | `terraform destroy` |
| EKS addons | `terraform destroy` |
| VPC + all subnets | `terraform destroy` / manual |
| NAT Gateway | `terraform destroy` / manual |
| Internet Gateway | `terraform destroy` / manual |
| Route tables | `terraform destroy` / manual |
| Security groups | `terraform destroy` / manual |
| KMS key + alias | `terraform destroy` / manual |
| CloudWatch log group | `terraform destroy` / manual |
| Elastic IP | manual |
| ECR repository | manual |
| Secrets Manager secret | manual |
| S3 Terraform state bucket | manual |
| DynamoDB lock table | manual |
| Local kubeconfig context | manual |

---

## Common Errors and Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `Cluster already exists` | Manual cluster exists, not in Terraform state | Delete cluster manually, clear state, re-apply |
| `EBS CSI CrashLoopBackOff` | Missing IRSA role for EBS CSI | Run `eksctl create iamserviceaccount` for ebs-csi-controller-sa |
| `KMS alias already exists` | Previous cluster left KMS alias behind | Run `aws kms delete-alias --alias-name alias/eks/eks-platform-dev` |
| `State checksum mismatch` | Interrupted apply left S3/DynamoDB out of sync | Update DynamoDB Digest item with correct MD5 from error message |
| `Large file rejected by GitHub` | `.terraform/` provider binaries committed | Add `.gitignore`, run `git rm -r --cached terraform/.terraform/`, force push |
| `ArgoCD applicationset-controller crash` | CRD annotation too large | Remove `last-applied-configuration` annotation from CRD, restart controller |
| `localhost refused to connect` | Port-forward stopped | Re-run `kubectl port-forward svc/argocd-server -n argocd 8080:443 &` |
| `UnauthorizedOperation ec2:DescribeAvailabilityZones` | Node IAM role lacks EBS permissions | Create IRSA service account with `AmazonEBSCSIDriverPolicy` |
| `BucketNotEmpty` on S3 delete | Versioned bucket has version history | Delete all versions and delete markers first, then remove bucket |
| `DependencyViolation` on security group delete | SGs reference each other in rules | Revoke all ingress/egress rules from both SGs first, then delete |
| `VPC has dependent objects` | Subnets, IGW, or route tables still exist | Delete in order: NAT GW → Elastic IP → subnets → IGW → route tables → security groups → VPC |

---

## Author

**Manojkumar** · [github.com/ManojKumar-Devops](https://github.com/ManojKumar-Devops)
