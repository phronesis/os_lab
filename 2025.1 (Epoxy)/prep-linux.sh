#! /bin/bash

# To run this script in freshly installed Ubuntu 24.04:
# $ wget "https://raw.githubusercontent.com/kriscelmer/os_lab/refs/heads/main/2025.1%20(Epoxy)/prep-linux.sh"
# $ bash prep-linux.sh
# Follow on screen instructions
#
# NETWORK INTERFACE CONFIGURATION:
# By default, this script auto-detects network interfaces on your system.
# If auto-detection fails or you want to use specific interfaces, set these environment variables:
#
# $ export NETWORK_INTERFACE=eth0           # Your primary network interface (will get 10.0.0.11)
# $ export NEUTRON_EXTERNAL_INTERFACE=eth1  # Interface for Neutron external network (no IP needed)
# $ bash prep-linux.sh
#
# To see available interfaces, run: ip link show

echo "---> Prepare Ubuntu Linux for OpenStack 2025.1 (Epoxy) All-in-One Lab"
echo ""
set -e

echo "---> Configuring openstack user account for passwordless sudo"
echo "openstack ALL=(ALL:ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/openstack
echo "<---"

echo "---> Auto-detecting network interfaces"
# Allow user to override network interfaces via environment variables
if [ -z "$NETWORK_INTERFACE" ]; then
    # Try to find the default route interface
    NETWORK_INTERFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)

    # Fallback to common interface names if still not found
    if [ -z "$NETWORK_INTERFACE" ]; then
        for iface in ens33 eth0 enp0s3 enp0s8; do
            if ip link show "$iface" &>/dev/null; then
                NETWORK_INTERFACE="$iface"
                break
            fi
        done
    fi
fi

if [ -z "$NEUTRON_EXTERNAL_INTERFACE" ]; then
    # Try to find the second network interface for Neutron external network
    NEUTRON_EXTERNAL_INTERFACE=$(ip link show 2>/dev/null | grep -E '^[0-9]+: ' | grep -v "lo:" | awk -F': ' '{print $2}' | grep -v "$NETWORK_INTERFACE" | head -n1)

    # Fallback to common names
    if [ -z "$NEUTRON_EXTERNAL_INTERFACE" ]; then
        for iface in ens34 eth1 enp0s9; do
            if ip link show "$iface" &>/dev/null; then
                NEUTRON_EXTERNAL_INTERFACE="$iface"
                break
            fi
        done
    fi
fi

# Set defaults if still empty
NETWORK_INTERFACE="${NETWORK_INTERFACE:-ens33}"
NEUTRON_EXTERNAL_INTERFACE="${NEUTRON_EXTERNAL_INTERFACE:-ens34}"

echo "Network Interface (will be configured with 10.0.0.11): $NETWORK_INTERFACE"
echo "Neutron External Interface (no IP): $NEUTRON_EXTERNAL_INTERFACE"
echo "NOTE: If these are incorrect, cancel (Ctrl+C) and set NETWORK_INTERFACE and NEUTRON_EXTERNAL_INTERFACE environment variables before running this script."
echo "Continuing in 5 seconds..."
sleep 5
echo "<---"

echo "---> Configuring netplan networking configuration"
# Get all interfaces except loopback and the ones we're already configuring
OTHER_INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | grep -v "$NETWORK_INTERFACE" | grep -v "$NEUTRON_EXTERNAL_INTERFACE")

cat << EOF | sudo tee /etc/netplan/01-netcfg.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $NETWORK_INTERFACE:
      dhcp4: false
      addresses: [ 10.0.0.11/24 ]
      routes: []          # no default route
      nameservers:
        addresses: [ 8.8.8.8, 8.8.4.4 ]   # use public DNS for general name resolution
    $NEUTRON_EXTERNAL_INTERFACE:
      dhcp4: false        # no IP (Neutron will use this interface)
      optional: true
EOF

# Add any other interfaces with DHCP
for iface in $OTHER_INTERFACES; do
    cat << EOF | sudo tee -a /etc/netplan/01-netcfg.yaml
    $iface:
      dhcp4: true
      optional: true
EOF
done

sudo netplan apply
sudo rm -f /etc/netplan/50-cloud-init.yaml
echo "<---"

echo "---> Enabling and verifying IP forwarding"
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
sudo sysctl net.ipv4.ip_forward
echo "<---"

echo "---> Disabling cloud-init"
sudo touch /etc/cloud/cloud-init.disabled
echo "<---"

echo "---> Installing apt-utils to enable noniteractive apt frontend"
sudo apt install -y apt-utils
export DEBIAN_FRONTEND=noninteractive 
echo "<---"

echo "---> Disabling Ubuntu automatic upgrades"
sudo apt remove -y unattended-upgrades
echo "<---"

echo "---> Updating and installing basic packages"
sudo apt update && sudo apt upgrade -y
sudo apt install -y bridge-utils cpu-checker qemu-kvm parted
sudo apt install -y python3-dev python3-venv git libffi-dev gcc libssl-dev libdbus-glib-1-dev vim nano net-tools htop dnsutils yq tree bc
echo "<---"

echo "---> Preparing second disk for Cinder LVM volume groups"
# Initialize the disk as a PV
sudo pvcreate /dev/sda

# Verify PV creation (optional)
sudo pvs

# Create the first VG using the first partition
sudo vgcreate cinder-volumes /dev/sda

# Verify VG creation
sudo vgs
echo "<---"

echo "--> Mounting configfs"
echo "configfs /sys/kernel/config configfs defaults 0 0" | sudo tee -a /etc/fstab
sudo mount -a
echo "<---"

echo "---> Making sure DBUS library is installed"
sudo apt install -y python3-dbus
echo "<---"

echo "---> Fetch remaining scripts from GitHub"
curl -L https://github.com/kriscelmer/os_lab/archive/refs/heads/main.tar.gz | \
  tar -xz --wildcards --strip-components=3 --no-anchored "os_lab-main/2025.1 (Epoxy)/scripts/*" -C .
echo "<---"

cat << EOF

Ubuntu Linux is now configured and ready for Kolla Ansible OpenStack deployment.
Shutdown the system with:

sudo shutdown now

(Optionally take the VM snapshot in VMware Workstation Pro.)

Restart the VM and run deploy-openstack.sh script to continue OpenStack Lab deployment.
You can SSH to Ubuntu VM from Windows host with:

ssh openstack@10.0.0.11

You may need to remove old SSH keys with:

ssh-keygen -R 10.0.0.11

EOF
