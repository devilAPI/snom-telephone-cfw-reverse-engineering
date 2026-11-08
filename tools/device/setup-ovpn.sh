#!/bin/bash
set -e

# Config parameters
CERT_DIR="/etc/openvpn/certs"
CLIENT_DIR="/tmp/snom-client"
SERVER_IP=$(hostname -I | awk '{print $1}') # Replace with public IP/DDNS if behind NAT

echo "[+] Installing packages..."
sudo pacman -S --needed openvpn tar openssl --noconfirm

echo "[+] Creating PKI directory structure..."
sudo mkdir -p "$CERT_DIR" "$CLIENT_DIR"
cd "$CERT_DIR"

echo "[+] 1. Generating CA Private Key and Certificate..."
sudo openssl genpkey -algorithm RSA -out ca.key -pkeyopt rsa_keygen_bits:2048
sudo openssl req -new -x509 -key ca.key -out ca.crt -days 3650 \
  -subj "/CN=Snom-OpenVPN-CA"

echo "[+] 2. Generating Server Key and Certificate..."
sudo openssl genpkey -algorithm RSA -out server.key -pkeyopt rsa_keygen_bits:2048
sudo openssl req -new -key server.key -out server.csr \
  -subj "/CN=OpenVPN-Server"

# Sign Server Certificate
sudo openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 3650

echo "[+] 3. Generating Client Key and Certificate for Snom Phone..."
sudo openssl genpkey -algorithm RSA -out client.key -pkeyopt rsa_keygen_bits:2048
sudo openssl req -new -key client.key -out client.csr \
  -subj "/CN=snom-phone"

# Sign Client Certificate
sudo openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 3650

echo "[+] 4. Generating TLS Auth Key..."
sudo openvpn --genkey secret ta.key

echo "[+] 5. Writing OpenVPN Server Configuration..."
sudo mkdir -p /etc/openvpn/server
cat << EOF | sudo tee /etc/openvpn/server/server.conf > /dev/null
port 1194
proto udp
dev tun

ca $CERT_DIR/ca.crt
cert $CERT_DIR/server.crt
key $CERT_DIR/server.key
dh none

server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
keepalive 10 60

tls-auth $CERT_DIR/ta.key 0
cipher AES-256-CBC
auth SHA256

user nobody
group nobody
persist-key
persist-tun

status /var/log/openvpn-status.log
verb 3
EOF

echo "[+] 6. Enabling IPv4 Forwarding & Systemd Service..."
echo "net.ipv4.ip_forward = 1" | sudo tee /etc/sysctl.d/30-ipforward.conf > /dev/null
sudo sysctl --system
sudo systemctl enable --now openvpn-server@server

echo "[+] 7. Creating Snom OpenVPN archive..."
cd "$CLIENT_DIR"

cat << EOF > vpn.conf
client
dev tun
proto udp
remote $SERVER_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
script-security 2
up /usr/local/bin/startsshd

ca ca.crt
cert client.crt
key client.key

remote-cert-tls server
tls-auth ta.key 1
cipher AES-256-CBC
auth SHA256
verb 3
EOF

# Copy generated keys and certificates
sudo cp "$CERT_DIR/ca.crt" .
sudo cp "$CERT_DIR/client.crt" .
sudo cp "$CERT_DIR/client.key" .
sudo cp "$CERT_DIR/ta.key" .
sudo chown -R $USER:$USER "$CLIENT_DIR"

# Build openvpn.tar
tar -cvf ~/openvpn.tar vpn.conf ca.crt client.crt client.key ta.key

echo "--------------------------------------------------------"
echo "Done! The OpenVPN package was saved to: ~/openvpn.tar"
echo "Upload this file via Snom Web Interface -> Advanced -> Update -> OpenVPN."
