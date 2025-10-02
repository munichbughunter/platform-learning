#!/usr/bin/env bash
set -euo pipefail

echo "=== My Platform Learning Bootstrap ==="
echo "This script sets up the local environment for my Platform Learning."
echo ""

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
CLUSTER_NAME="platform-learning"
GITHUB_USER="munichbughunter" # Replace via env var
IMAGE_REGISTRY="ghcr.io/${GITHUB_USER}"

# Functions
check_command() {
    if command -v "$1" &> /dev/null; then
        echo -e "${GREEN}✔${NC} $1 is installed"
    else
        echo -e "${RED}✘${NC} $1 is not installed. Please install it and rerun the script."
        exit 1
    fi
}

print_section() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# 1. Check prerequisites
print_section "Step 1: Check prerequisites"
MISSING=0

check_command docker || MISSING=1
check_command kubectl || MISSING=1
check_command k3d || MISSING=1
check_command helm || MISSING=1

if [ $MISSING -eq 1 ]; then
    echo ""
    echo -e "${RED}✗ Missing tools found!${NC}"
    echo ""
    echo -e "${YELLOW}Installation instructions:${NC}"
    echo ""
    echo "Docker:"
    echo "  https://docs.docker.com/get-docker/"
    echo ""
    echo "kubectl:"
    echo "  curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
    echo "  chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
    echo ""
    echo "k3d:"
    echo "  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
    echo ""
    echo "helm:"
    echo "  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    echo ""
    exit 1
fi

echo ""
echo -e "${GREEN}✓ All prerequisites are installed${NC}"

# 2. Setup GitHub Container Registry
print_section "Step 2: GitHub Container Registry Authentication"

echo -e "${YELLOW}INFO:${NC} To push images to ghcr.io, you need a GitHub token"
echo "Create a token here: https://github.com/settings/tokens/new"
echo "Required permissions: write:packages, read:packages"
echo ""

if [ -z "${GH_TOKEN:-}" ]; then
    echo -e "${YELLOW}⚠  GH_TOKEN environment variable not set${NC}"
    echo ""
    echo "You have the following options:"
    echo "  1) Enter token now (for this bootstrap)"
    echo "  2) Set manually later: export GH_TOKEN=ghp_..."
    echo "  3) Continue without token (images will only be built locally)"
    echo ""
    read -p "Do you want to enter a token now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -sp "GitHub Token: " GH_TOKEN
        echo
        export GH_TOKEN
    else
        echo -e "${YELLOW}⚠  Continue without token - images will only be built locally${NC}"
    fi
fi

# Docker Login to ghcr.io
if [ -n "${GH_TOKEN:-}" ]; then
    echo "Logging in to ghcr.io..."
    echo "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_USER" --password-stdin 2>/dev/null
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} GitHub Container Registry Login successful"
    else
        echo -e "${RED}✗${NC} Login failed - check your token"
        exit 1
    fi
else
    echo -e "${YELLOW}⚠${NC}  No GitHub Token - skipping GHCR Login"
fi

# 3. k3d Cluster Setup
print_section "Step 3: k3d Kubernetes Cluster Setup"

if k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    echo -e "${YELLOW}⚠${NC} Cluster '$CLUSTER_NAME' already exists. Skipping creation."
    read -p "Do you want to delete and recreate it? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Deleting existing cluster..."
        k3d cluster delete "$CLUSTER_NAME"
    else
        echo "Using existing cluster."
    fi
fi

if ! k3d cluster list 2>/dev/null | grep -q "$CLUSTER_NAME"; then
    echo "Creating k3d cluster '$CLUSTER_NAME' with following configuration:"
    echo "  - 1 Server Node"
    echo "  - 2 Agent Nodes"
    echo "  - LoadBalancer Port 8080 → 80"
    echo "  - LoadBalancer Port 8443 → 443"
    echo ""

    k3d cluster create "$CLUSTER_NAME" \
        --api-port "6550" \
        --servers 1 \
        --agents 2 \
        --port "8080:80@loadbalancer" \
        --port "8443:443@loadbalancer" \
        --wait \
        --timeout 120s

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Cluster '$CLUSTER_NAME' created successfully"
    else
        echo -e "${RED}✗${NC} Failed to create cluster"
        exit 1
    fi
fi

# Set kubeconfig context
print_section "Step 4: Set kubeconfig context"
export KUBECONFIG="$(k3d kubeconfig write "$CLUSTER_NAME")"
echo "KUBECONFIG set: $KUBECONFIG"

# Verify cluster access
echo "Verifying access to the cluster..."
kubectl cluster-info
kubectl get nodes

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Cluster ist erreichbar"
else
    echo -e "${RED}✗${NC} Cluster nicht erreichbar"
    exit 1
fi

# 5. Create namespaces
print_section "Step 5: Create Kubernetes Namespaces"

# Create namespace directories if they don't exist
cat > ./infrastructure/k8s/namespaces/platform-learning-dev.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: platform-learning-dev
  labels:
    environment: dev
    managed-by: argocd
EOF

cat > ./infrastructure/k8s/namespaces/platform-learning-prod.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: platform-learning-prod
  labels:
    environment: prod
    managed-by: argocd
EOF

kubectl apply -f infrastructure/k8s/namespaces/
echo -e "${GREEN}✓${NC} Namespaces created"

# 6. Create ImagePullSecret for ghcr.io
print_section "Step 6: Create ImagePullSecret for ghcr.io"
if [ -n "${GH_TOKEN:-}" ]; then
    for NS in platform-learning-dev platform-learning-prod; do
        kubectl create secret docker-registry ghcr-secret \
            --docker-server=ghcr.io \
            --docker-username="$GITHUB_USER" \
            --docker-password="$GH_TOKEN" \
            --namespace="$NS" \
            --dry-run=client -o yaml | kubectl apply -f -
        
        echo -e "${GREEN}✓${NC} ImagePullSecret in Namespace $NS created"
    done
else
    echo -e "${YELLOW}⚠${NC}  Skipping ImagePullSecret creation (no token)"
    echo "    Note: Use public images or create secret later with:"
    echo "    kubectl create secret docker-registry ghcr-secret --docker-server=ghcr.io ..."
fi

# 7. Install ArgoCD
print_section "Step 7: Install ArgoCD in 'ArgoCD'"

if kubectl get namespace argocd &> /dev/null; then
    echo -e "${YELLOW}⚠ ArgoCD namespace already exists. Skipping ArgoCD installation.${NC} "
else
    echo "Creating 'ArgoCD' namespace and installing ArgoCD..."
    kubectl create namespace argocd
    echo "Installing ArgoCD (stable release)..."
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

    echo "Waiting for ArgoCD pods to be ready (can take a few minutes)..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=argocd-server \
        -n argocd \
        --timeout=300s
    
    echo -e "${GREEN}✓${NC} ArgoCD installed and pods are ready"
fi

# ArgoCD Service as LoadBalancer exposure (for k3d)
echo "Exposing ArgoCD Service as LoadBalancer..."
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'

# ArgoCD Initial Admin Password
ARGOCD_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)

if [ -z "$ARGOCD_ADMIN_PASSWORD" ]; then
    echo -e "${YELLOW}⚠  Initial Admin Secret not yet available (ArgoCD still starting up)${NC}"
    echo "    Retrieve the password later with the following command:"
    echo "    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
else
    echo -e "${GREEN}✓${NC} ArgoCD Admin Password retrieved"
fi

# 8. Register Git Repository in ArgoCD (if token is available)
print_section "Step 8: Configure Git Repository in ArgoCD"

if [ -n "${GH_TOKEN:-}" ]; then
    echo "Registering Git Repository in ArgoCD..."

    kubectl create secret generic platform-repo-secret \
        --from-literal=type=git \
        --from-literal=url=https://github.com/${GITHUB_USER}/platform-learning.git \
        --from-literal=password="$GH_TOKEN" \
        --from-literal=username="$GITHUB_USER" \
        --namespace=argocd \
        --dry-run=client -o yaml | kubectl apply -f -
    
    kubectl label secret platform-repo-secret \
        argocd.argoproj.io/secret-type=repository \
        -n argocd \
        --overwrite

    echo -e "${GREEN}✓${NC} Git Repository registered in ArgoCD"
else
    echo -e "${YELLOW}⚠${NC}  Skipping Git Repo registration (no token)"
    echo "    Note: Configure private repos later in ArgoCD UI"
fi

# 9. Summary
print_section "Bootstrap done!"

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Platform Learning Setup successful!              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Cluster Information:${NC}"
echo "  Name:          $CLUSTER_NAME"
echo "  Kubeconfig:    $KUBECONFIG"
echo "  Nodes:         $(kubectl get nodes --no-headers | wc -l)"
echo ""
echo -e "${BLUE}ArgoCD Access:${NC}"
echo "  URL:           http://localhost:8080"
echo "  Username:      admin"
if [ -n "$ARGOCD_PASSWORD" ]; then
    echo "  Password:      $ARGOCD_PASSWORD"
else
    echo "  Password:      (not yet available - see note below)"
fi
echo ""
echo -e "${BLUE}Alternative with Port-Forward:${NC}"
echo "  kubectl port-forward svc/argocd-server -n argocd 8081:443"
echo "  https://localhost:8081"
echo ""
echo -e "${BLUE}Useful Commands:${NC}"
echo "  make status              # how status of all services"
echo "  make argocd-ui           # ArgoCD UI Port-Forward"
echo "  make argocd-password     # Show ArgoCD Password"
echo "  make build-all           # Build all images"
echo "  make logs-frontend       # Show frontend logs"
echo "  make logs-backend        # Show backend logs"
echo "  make clean               # Delete cluster"
echo ""
echo -e "${BLUE}Image Registry:${NC}"
echo "  Registry:      ghcr.io/${GITHUB_USER}"
echo "  Frontend:      ghcr.io/${GITHUB_USER}/platform-frontend:latest"
echo "  Backend Java:  ghcr.io/${GITHUB_USER}/platform-backend-java:latest"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. Create application files (Frontend, Backend)"
echo "  2. Create Kubernetes manifests (Helm Charts)"
echo "  3. Create ArgoCD Applications"
echo "  4. Deploy with: make deploy"
echo ""
echo "Documentation: see docs/ARCHITECTURE.md"
echo ""