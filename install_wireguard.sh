#!/bin/bash

# WireGuard VPN Installation Script for AWS EC2 (Amazon Linux)
# Uses a simple configuration file for IP, port, DNS, and users

CONFIG_FILE="wireguard_config.conf"

# Check if the configuration file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Configuration file '$CONFIG_FILE' not found!"
    exit 1
fi

# Function to read configuration values
read_config() {
    grep -i "^$1" "$CONFIG_FILE" | cut -d '=' -f 2 | tr -d ' '
}

# Read server settings from config file
SERVER_IP=$(read_config "ServerIP")
LISTEN_PORT=$(read_config "ListenPort")
DNS=$(read_config "DNS")
USERS=$(read_config "Users")

# Convert users string to an array
IFS=',' read -r -a USER_ARRAY <<< "$USERS"

# Step 1: Update the System
echo "Updating the system..."
sudo yum update -y

# Step 2: Install WireGuard and Dependencies
echo "Installing WireGuard and dependencies..."
sudo amazon-linux-extras install epel -y
sudo yum install wireguard-tools iptables -y

# Step 3: Enable WireGuard Kernel Module
echo "Enabling WireGuard kernel module..."
sudo modprobe wireguard
lsmod | grep wireguard

# Step 4: Generate Server Keys
echo "Generating server keys..."
umask 077
wg genkey | sudo tee /etc/wireguard/privatekey | wg pubkey | sudo tee /etc/wireguard/publickey

# Step 5: Create Server Configuration File
echo "Creating server configuration file..."
SERVER_PRIVATE_KEY=$(sudo cat /etc/wireguard/privatekey)
SERVER_PUBLIC_KEY=$(sudo cat /etc/wireguard/publickey)
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')

sudo cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = $SERVER_IP
SaveConfig = true
ListenPort = $LISTEN_PORT
PrivateKey = $SERVER_PRIVATE_KEY
DNS = $DNS
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE
EOF

# Step 6: Enable IP Forwarding
echo "Enabling IP forwarding..."
sudo sh -c "echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf"
sudo sysctl -p

# Step 7: Generate Keys for Clients
echo "Generating keys for clients..."
sudo mkdir -p /etc/wireguard/clients

# Loop through users and generate keys
CLIENT_IP_PREFIX="10.0.0."
CLIENT_IP_COUNTER=2

for USER in "${USER_ARRAY[@]}"; do
    echo "Setting up client: $USER..."

    # Generate keys
    umask 077
    wg genkey | sudo tee /etc/wireguard/clients/${USER}_privatekey | wg pubkey | sudo tee /etc/wireguard/clients/${USER}_publickey

    # Add client to server configuration
    CLIENT_PUBLIC_KEY=$(sudo cat /etc/wireguard/clients/${USER}_publickey)
    CLIENT_IP="${CLIENT_IP_PREFIX}${CLIENT_IP_COUNTER}/32"
    sudo sh -c "echo -e '\n[Peer]\nPublicKey = $CLIENT_PUBLIC_KEY\nAllowedIPs = $CLIENT_IP' >> /etc/wireguard/wg0.conf"

    # Create client configuration file
    CLIENT_PRIVATE_KEY=$(sudo cat /etc/wireguard/clients/${USER}_privatekey)
    EC2_PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)

    sudo cat > /etc/wireguard/clients/${USER}.conf <<EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = ${CLIENT_IP_PREFIX}${CLIENT_IP_COUNTER}/24
DNS = $DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0
Endpoint = $EC2_PUBLIC_IP:$LISTEN_PORT
PersistentKeepalive = 25
EOF

    # Increment IP counter
    CLIENT_IP_COUNTER=$((CLIENT_IP_COUNTER + 1))
done

# Step 8: Start WireGuard Service
echo "Starting WireGuard service..."
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0

# Step 9: Share Configuration Files with Clients
echo "WireGuard VPN setup is complete!"
echo "Client configuration files are located in /etc/wireguard/clients/"
echo "Use SCP or a secure method to transfer these files to your client devices."

# Step 10: Test the Connection
echo "To test the connection, start the WireGuard client on each device and connect to the VPN."
echo "Check the status of WireGuard on the server using: sudo wg"
echo "Test connectivity by pinging the server’s VPN IP ($SERVER_IP) and an external IP (e.g., 8.8.8.8)."

echo "Enjoy your private and secure VPN! 🚀"

echo ""
echo "------------------------ Client Configurations ------------------------"
echo ""

for USER in "${USER_ARRAY[@]}"; do
    echo "Client: $USER"
    echo "------------------------------------------------------------------"
    sudo cat /etc/wireguard/clients/${USER}.conf
    echo ""
done

echo "------------------------------------------------------------------"