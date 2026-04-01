#!/bin/bash
set -e

# --- Configuration ---
VIP="192.168.0.10" 
# Dynamically find the default interface if you don't want to hardcode it
INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )[^ ]+' || echo "eth0")
K3S_TOKEN="Th0rxLGGbI2qFMUp"

# --- Helper Functions ---
# Function to check if the last command succeeded
check_status() {
    if [ $? -ne 0 ]; then
        echo "ERROR: $1 failed. See above for details."
        exit 1
    else
        echo "SUCCESS: $1 completed."
    fi
}

# Function to wait for a specific Kubernetes resource to be ready
wait_for_resource() {
    echo "Waiting for $1 to be ready..."
    sleep 5
    until kubectl get "$1" > /dev/null 2>&1; do
        echo "  ...still waiting for $1..."
        sleep 5
    done
}

echo "Step 1: Installing K3s..."

curl -sfL https://get.k3s.io | sh -s - server \
  --token="${K3S_TOKEN}" \
  --tls-san="${VIP}" \
  --disable servicelb \
  --disable traefik \
  --cluster-init \
  --write-kubeconfig-mode 644
check_status "K3s installation"

wait_for_resource "node $(hostname)"

echo "Setting up firewalls rules..."

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 6443/tcp
sudo ufw allow 2379:2380/tcp
sudo ufw allow 8472/udp
sudo ufw allow 10250/tcp
# Optional: Allow standard web traffic if using an Ingress
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable

check_status "Firewall configuration"

echo "Step 2: Setting up kube-vip RBAC..."

mkdir -p /var/lib/rancher/k3s/server/manifests/

curl -sSL https://kube-vip.io/manifests/rbac.yaml > /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml

check_status "kube-vip RBAC download"

echo "Step 3: Generating kube-vip DaemonSet..."

KVVERSION=$(curl -sL https://github.com | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

# Run the container directly instead of using an alias
sudo ctr run --rm --net-host "ghcr.io/kube-vip/kube-vip:$KVVERSION" vip /kube-vip manifest daemonset \
    --interface "$INTERFACE" \
    --address "$VIP" \
    --inCluster \
    --controlplane \
    --arp \
    --leaderElection \
    --taint \
    | sudo tee /var/lib/rancher/k3s/server/manifests/kube-vip-daemonset.yaml > /dev/null

check_status "kube-vip manifest generation"

echo "Step 4: Verifying Virtual IP (VIP) Activation..."
echo "Waiting for kube-vip to bind $VIP to $INTERFACE..."
sleep 15 # Give the DaemonSet time to pull the image and start

# Check 1: Does the interface show the IP?
if ip addr show "$INTERFACE" | grep -q "$VIP"; then
    echo "✅ VIP $VIP is locally active on $INTERFACE."
else
    # Check 2: Can we ping it? (In case another node already took the VIP)
    if ping -c 1 -W 1 "$VIP" > /dev/null 2>&1; then
        echo "✅ VIP $VIP is active on the network (reachable via ping)."
    else
        echo "❌ ERROR: VIP $VIP is NOT active. Check 'kubectl logs -n kube-system -l name=kube-vip-ds'"
        exit 1
    fi
fi

echo "Setting KUBECONFIG path..."
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc

echo "Step 4: Final verification..."
# Give K3s a moment to pick up the new manifest
sleep 10
wait_for_resource "daemonset kube-vip-ds -n kube-system"

echo "---------------------------------------------------"
echo "INSTALLATION SUCCESSFUL"
echo "Virtual IP: $VIP"
echo "Interface:  $INTERFACE"
echo "Check nodes: kubectl get nodes"
echo "---------------------------------------------------"