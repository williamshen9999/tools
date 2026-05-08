#!/bin/bash

# ==============================================================================
# Script: install_rancher.sh
# Description: Automate K3s/RKE2 + Rancher with Step-by-Step UI feedback.
# ==============================================================================

set -e 

# --- [STEP 0] Initial Setup Questions ---
echo "=================================================="
echo " [STEP 0] Initial Setup Questions"
echo "=================================================="

# Q1: Choose Platform
read -p ">> Do you want to install rke2 or k3s? [default: rke2]: " PLATFORM
PLATFORM="${PLATFORM:-rke2}"

# Q2: Choose Rancher Channel
while true; do
    read -p ">> Rancher version type? (s for stable / a for alpha) [default: s]: " CHANNEL_INPUT
    CHANNEL_INPUT="${CHANNEL_INPUT:-s}"
    case $CHANNEL_INPUT in
        [Ss]* ) RANCHER_CHANNEL="stable"; break;;
        [Aa]* ) RANCHER_CHANNEL="alpha"; break;;
        * ) echo "Please answer 's' or 'a'.";;
    esac
done

# Q3: Choose Version
read -p ">> Enter Rancher version (blank for latest ${RANCHER_CHANNEL}): " VERSION

# Q4: SBOM Scanner Pre-install
read -p ">> Enable SBOMScanner pre-install (StorageClass)? (Y/N) [default: Y]: " RUN_PREINSTALL
RUN_PREINSTALL="${RUN_PREINSTALL:-Y}"

echo -e "\nStarting deployment of $PLATFORM with Rancher $RANCHER_CHANNEL...\n"

# --- [STEP 1] Install K3s or RKE2 ---
echo "=================================================="
echo " [STEP 1] Installing $PLATFORM Infrastructure"
echo "=================================================="
if [[ "$PLATFORM" == "k3s" ]]; then
    SERVICE_NAME="k3s"
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "--> Running K3s installation script..."
        curl -sfL https://get.k3s.io | sudo sh -
    else
        echo "--> K3s is already running. Skipping install."
    fi
else
    SERVICE_NAME="rke2-server"
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        echo "--> Running RKE2 installation script..."
        curl -sfL https://get.rke2.io | sudo sh -
        echo "--> Enabling and starting RKE2 service..."
        sudo systemctl enable --now "$SERVICE_NAME"
    else
        echo "--> RKE2 is already running. Skipping install."
    fi
fi

echo "--> Waiting for ${SERVICE_NAME} to become active..."
until sudo systemctl is-active --quiet "${SERVICE_NAME}"; do sleep 5; done
echo "--> SUCCESS: ${SERVICE_NAME} is active."

echo "--> Sleep 30s for ingress to activate"
sleep 30

# --- [STEP 2] Configure Shell Environment ---
echo -e "\n=================================================="
echo " [STEP 2] Configuring Shell Environment (~/.bashrc)"
echo "=================================================="
BASHRC="$HOME/.bashrc"
if [[ "$PLATFORM" == "rke2" ]]; then
    EXPORT_KUBE="export KUBECONFIG=/etc/rancher/rke2/rke2.yaml"
    EXPORT_PATH="export PATH=\$PATH:/var/lib/rancher/rke2/bin"
else
    EXPORT_KUBE="export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
    EXPORT_PATH="export PATH=\$PATH:/usr/local/bin"
fi

if ! grep -q "KUBECONFIG" "$BASHRC"; then
    echo "--> Adding exports and alias 'k' to $BASHRC"
    echo "$EXPORT_KUBE" >> "$BASHRC"
    echo "$EXPORT_PATH" >> "$BASHRC"
    echo "alias k='kubectl'" >> "$BASHRC"
    echo "source <(kubectl completion bash)" >> "$BASHRC"
    echo "complete -o default -F __start_kubectl k" >> "$BASHRC"
else
    echo "--> Environment already configured. Skipping."
fi

eval "$EXPORT_KUBE"
eval "$EXPORT_PATH"
alias k='kubectl'
echo "--> Current session environment updated."

# --- [STEP 3] Install Helm ---
echo -e "\n=================================================="
echo " [STEP 3] Installing Helm Binary"
echo "=================================================="
if ! command -v helm &> /dev/null; then
    echo "--> Downloading and installing Helm..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod 700 get_helm.sh && ./get_helm.sh && rm get_helm.sh
else
    echo "--> Helm is already installed: $(helm version --short)"
fi

# --- [STEP 4] Install Cert-Manager ---
echo -e "\n=================================================="
echo " [STEP 4] Deploying Cert-Manager"
echo "=================================================="
if ! helm list -n cert-manager | grep -q "cert-manager"; then
    echo "--> Adding Jetstack repo and installing cert-manager..."
    helm repo add jetstack https://charts.jetstack.io
    helm repo update
    helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true --wait
else
    echo "--> Cert-manager already exists. Skipping."
fi

# --- [STEP 5] Install Rancher Manager ---
echo -e "\n=================================================="
echo " [STEP 5] Deploying Rancher Manager ($RANCHER_CHANNEL)"
echo "=================================================="
if [[ "$RANCHER_CHANNEL" == "stable" ]]; then
    REPO_NAME="rancher-latest"
    REPO_URL="https://releases.rancher.com/server-charts/latest"
    HOSTNAME="rancher.example-stable.com"
else
    REPO_NAME="rancher-alpha"
    REPO_URL="https://releases.rancher.com/server-charts/alpha"
    HOSTNAME="rancher.example-test.com"
fi

if ! helm list -n cattle-system | grep -q "rancher"; then
    echo "--> Adding Rancher $RANCHER_CHANNEL repo..."
    helm repo add "$REPO_NAME" "$REPO_URL"
    helm repo update
    
    VERSION_FLAG=""; [ -n "$VERSION" ] && VERSION_FLAG="--version $VERSION"
    DEVEL_FLAG=""; [ "$RANCHER_CHANNEL" == "alpha" ] && DEVEL_FLAG="--devel"

    echo "--> Creating cattle-system namespace..."
    kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -
    
    echo "--> Starting Rancher Helm installation..."
    helm install rancher "${REPO_NAME}/rancher" \
      --namespace cattle-system \
      --set hostname="$HOSTNAME" \
      --set bootstrapPassword="admin" \
      --set replicas=1 \
      $VERSION_FLAG $DEVEL_FLAG

    echo "--> Waiting for Rancher pods to be Ready (this may take 2-5 mins)..."
    kubectl wait --namespace cattle-system --for=condition=Ready pod --all --timeout=300s

else
    echo "--> Rancher is already installed in cattle-system."
fi

# --- [STEP 6] NodePort Patch & IP Discovery ---
echo -e "\n=================================================="
echo " [STEP 6] Networking & Access Configuration"
echo "=================================================="
echo "--> Patching Rancher service to NodePort..."
kubectl patch svc rancher -n cattle-system -p '{"spec": {"type": "NodePort", "ports": [{"name": "http", "port": 80, "nodePort": 32232}, {"name": "https", "port": 443, "nodePort": 32047}]}}'

echo "--> Discovering Node IP address..."
NODE_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)

# --- [STEP 7] SBOMScanner Pre-install ---
echo -e "\n=================================================="
echo " [STEP 7] SBOMScanner Pre-install (Storage)"
echo "=================================================="
if [[ "$RUN_PREINSTALL" =~ ^[Yy]$ ]]; then
    if ! kubectl get sc | grep -q "local-path"; then
        echo "--> Applying Local Path Provisioner..."
        kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
        echo "--> Setting local-path as Default StorageClass..."
        kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class="true" --overwrite
    else
        echo "--> StorageClass 'local-path' already exists."
    fi
else
    echo "--> Pre-install skipped by user."
fi

echo -e "\n=================================================="
echo " FINISHED SUCCESSFULLY!"
echo "=================================================="
echo " Access URL: https://${NODE_IP}:32047"
echo " Bootstrap Password: admin"
echo -e " IMPORTANT: Run the following command now:\n"
echo "      source ~/.bashrc"
echo "=================================================="

