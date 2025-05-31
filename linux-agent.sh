#!/bin/bash
set -e

# Optional: Disable IPv6 for clean network behavior
echo "Disabling IPv6..."
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1

# Download GPG key
echo "Fetching GPG key..."
curl -fsSL https://packages.defendx.io/linux/defendx-agent.gpg.key | gpg --dearmor -o /usr/share/keyrings/defendx.gpg

# Add APT source list
echo "Adding APT repository..."
echo "deb [signed-by=/usr/share/keyrings/defendx.gpg] https://packages.defendx.io/linux stable main" | tee /etc/apt/sources.list.d/defendx.list

# Update and install
echo "Updating APT cache..."
apt update

echo "Installing defendx-agent..."
apt install -y defendx-agent

echo "✅ DefendX Agent installation complete!"
