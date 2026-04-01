#!/bin/bash
# set -e

# --- Configuration (MUST MATCH NODE 1) ---
FIRST_MASTER_IP="192.168.0.11"  # <--- CHANGE THIS to the IP of your first node
VIP="192.168.0.10"
K3S_TOKEN="Th0rxLGGbI2qFMUp"
INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )[^ ]+' || echo "eth0")

# --- Helper Functions ---
check_status() {
    if [ $? -ne 0 ]; then
        echo "❌ ERROR: $1 failed."
        exit 1
    else
        echo "✅ SUCCESS: $1 completed."
    fi
}

wait_for_node() {
    echo "⏳ Checking status of $1..."
    set +e
    # Give K3s a few seconds to start up before checking
    sleep 5
    OUTPUT=$(KUBECONFIG=/etc/rancher/k3s/k3s.yaml /usr/local/bin/kubectl get node "$1" 2>&1)
    EXIT_CODE=$?
    set -e
    if [ $EXIT_CODE -eq 0 ]; then
        echo "✅ Node found:"
        echo "$OUTPUT"
        return 0
    else
        echo "❌ ERROR: Node check failed!"
        echo "Message: $OUTPUT"
        exit 1
    fi
}

echo "Step 1: Setting up firewall rules..."
sudo ufw allow 22/tcp
sudo ufw allow 6443/tcp
sudo ufw allow 2379:2380/tcp
sudo ufw allow 8472/udp
sudo ufw allow 10250/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
check_status "Firewall configuration"

echo "Step 2: Joining K3s Cluster as Master..."
# NOTICE: We use --server and NO --cluster-init
curl -sfL https://get.k3s.io | sh -s - server \
  --server "https://${FIRST_MASTER_IP}:6443" \
  --token="${K3S_TOKEN}" \
  --tls-san="${VIP}" \
  --disable servicelb \
  --disable traefik \
  --write-kubeconfig-mode 644
check_status "K3s Join"

wait_for_node "$(hostname)"

echo "Step 3: Verifying kube-vip propagation..."
echo "Waiting for cluster to sync kube-vip to this node..."
sleep 20

# Check if the VIP moved to this node or is active elsewhere
if ip addr show "$INTERFACE" | grep -q "$VIP"; then
    echo "✅ This node is currently hosting the VIP $VIP."
elif ping -c 1 -W 1 "$VIP" > /dev/null 2>&1; then
    echo "✅ VIP $VIP is active on the network (hosted by another node)."
else
    echo "⚠️ VIP is not reachable yet. This is normal if the first node is still initializing."
fi

echo "Step 4: Setting KUBECONFIG path..."
if ! grep -q "KUBECONFIG" ~/.bashrc; then
    echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc
fi

echo "---------------------------------------------------"
echo "JOIN SUCCESSFUL"
echo "This node is now part of the HA control plane."
echo "---------------------------------------------------"
