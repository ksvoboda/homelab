#!/bin/bash
# set -e

# --- Configuration ---
VIP="192.168.0.10"
# Dynamically find the default interface if you don't want to hardcode it
INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )[^ ]+' || echo "eth0")
K3S_TOKEN="Th0rxLGGbI2qFMUp"

# --- Helper Functions ---
# Function to check if the last command succeeded
check_status() {
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: $1 failed. See above for details."
        exit 1
    else
        echo "✅ SUCCESS: $1 completed."
    fi
}

# Function to wait for a specific Kubernetes resource to be ready
wait_for_node() {
    echo "⏳ Checking status of $1..."

    # Capture both stdout and stderr into a variable
    # We use 'set +e' temporarily to handle the error manually
    set +e
    OUTPUT=$(KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl get node "$1" 2>&1)
    EXIT_CODE=$?
    set -e

    if [ $EXIT_CODE -eq 0 ]; then
        echo "✅ Resource found:"
        echo "$OUTPUT"
        echo "---------------------------------------------------"
        return 0
    else
        echo "❌ ERROR: Resource check failed!"
        echo "Message: $OUTPUT"
        exit 1
    fi
}

wait_for_vip() {
    echo "⏳ Checking status of "

    # Capture both stdout and stderr into a variable
    # We use 'set +e' temporarily to handle the error manually
    set +e
    OUTPUT=$(KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl get daemonset kube-vip-ds -n kube-system 2>&1)
    EXIT_CODE=$?
    set -e

    if [ $EXIT_CODE -eq 0 ]; then
        echo "✅ Resource found:"
        echo "$OUTPUT"
        echo "---------------------------------------------------"
        return 0
    else
        echo "❌ ERROR: Resource check failed!"
        echo "Message: $OUTPUT"
        exit 1
    fi
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

wait_for_node "$(hostname)"

echo "Step 2: Setting up firewalls rules..."

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

echo "Step 3: Setting up kube-vip RBAC..."

sudo mkdir -p /var/lib/rancher/k3s/server/manifests/

sudo curl -sSL https://kube-vip.io/manifests/rbac.yaml | sudo tee /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml > /dev/null

check_status "kube-vip RBAC download"

echo "Step 4: Generating kube-vip DaemonSet..."

KVVERSION=$(curl -sL https://api.github.com/repos/kube-vip/kube-vip/releases | jq -r ".[0].name")

export CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock

# 3. Pull the image into the k8s.io namespace first
sudo ctr -n k8s.io image pull ghcr.io/kube-vip/kube-vip:"$KVVERSION"
check_status "kube-vip image pull"

# Run the container directly instead of using an alias
sudo ctr -n k8s.io  run --rm --net-host "ghcr.io/kube-vip/kube-vip:$KVVERSION" vip /kube-vip manifest daemonset \
    --interface "$INTERFACE" \
    --address "$VIP" \
    --inCluster \
    --controlplane \
    --arp \
    --leaderElection \
    --taint \
    | sudo tee /var/lib/rancher/k3s/server/manifests/kube-vip-daemonset.yaml > /dev/null

check_status "kube-vip manifest generation"

echo "Verifying Virtual IP (VIP) Activation..."
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

echo "Step 5: Setting KUBECONFIG path..."
echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc

echo "Step 6: Final verification..."
# Give K3s a moment to pick up the new manifest
sleep 10
wait_for_vip

echo "---------------------------------------------------"
echo "INSTALLATION SUCCESSFUL"
echo "Virtual IP: $VIP"
echo "Interface:  $INTERFACE"
echo "Check nodes: kubectl get nodes"
echo "---------------------------------------------------"