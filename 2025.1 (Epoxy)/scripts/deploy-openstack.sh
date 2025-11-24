#! /bin/bash

# To run this script in freshly installed Ubuntu 24.04, first configure the OS by running 'prep-linux.sh' from the same repo
# 'prep-linux./sh' downloads the script into 'scripts' subfolder, otherwise fetch it from the repo:
# $ wget "https://raw.githubusercontent.com/kriscelmer/os_lab/refs/heads/main/2025.1%20(Epoxy)/scripts/deploy-openstack.sh"
# $ bash deploy-openstack.sh
# Script takes 20-45 minutes to complete
# Follow on screen instructions when script finishes
#
# NETWORK INTERFACE CONFIGURATION:
# By default, this script auto-detects network interfaces on your system.
# If auto-detection fails or you want to use specific interfaces, set these environment variables:
#
# $ export NETWORK_INTERFACE=eth0           # Your primary network interface
# $ export NEUTRON_EXTERNAL_INTERFACE=eth1  # Interface for Neutron external network (no IP needed)
# $ bash deploy-openstack.sh
#
# To see available interfaces, run: ip link show

echo "---> Deploy OpenStack 2025.1 (Epoxy) All-in-One Lab using Kolla-Ansible in Docker containers"
echo ""
set -e

echo "---> Creating and activating virtual environment"
cd ~
python3 -m venv --system-site-packages ~/openstack-venv
source ~/openstack-venv/bin/activate
pip install -U --quiet pip
echo "<---"

echo "---> Adding virtual environment activation to .bashrc"
echo "source ~/openstack-venv/bin/activate" >> ~/.bashrc
echo "<---"

echo "---> Installing Kolla-Ansible"
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2025.1
echo "<---"

echo "---> Installing Ansible Galaxy Dependencies"
kolla-ansible install-deps
echo "<---"

echo "---> Copying Configuration and Inventory Templates"
sudo mkdir -p /etc/kolla
sudo chown $USER:$USER /etc/kolla
# Copy example config files
cp -r  ~/openstack-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
# Copy all-in-one inventory to current directory for editing
cp  ~/openstack-venv/share/kolla-ansible/ansible/inventory/all-in-one .
echo "<---"

echo "---> Generating passwords for OpenStack services and users"
kolla-genpwd
echo "<---"

echo "---> Set password for 'admin' user"
sudo yq -i -y '.keystone_admin_password = "openstack"' /etc/kolla/passwords.yml
echo "<---"

echo "---> Auto-detecting network interfaces"
# Allow user to override network interfaces via environment variables
# If not set, try to auto-detect
if [ -z "$NETWORK_INTERFACE" ]; then
    # Try to find the primary network interface with IP 10.0.0.11
    NETWORK_INTERFACE=$(ip -4 addr show 2>/dev/null | grep "10.0.0.11" | awk '{print $NF}' | head -n1)

    # If not found, try to find any active interface (excluding loopback)
    if [ -z "$NETWORK_INTERFACE" ]; then
        NETWORK_INTERFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -n1)
    fi

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

echo "Network Interface: $NETWORK_INTERFACE"
echo "Neutron External Interface: $NEUTRON_EXTERNAL_INTERFACE"
echo "NOTE: If these are incorrect, cancel (Ctrl+C) and set NETWORK_INTERFACE and NEUTRON_EXTERNAL_INTERFACE environment variables before running this script."
echo "Continuing in 5 seconds..."
sleep 5
echo "<---"

echo "---> Configuring Kolla-Ansible (globals.yml)"
cat << EOF | tee -a /etc/kolla/globals.yml
# ---------------------------------------------------
#
# OpenStack Epoxy All-in-One Lab deployment configuration
#
# Configure Network Interfaces
network_interface: "$NETWORK_INTERFACE"
api_interface: "$NETWORK_INTERFACE"
neutron_external_interface: "$NEUTRON_EXTERNAL_INTERFACE"
dns_interface: "$NETWORK_INTERFACE"
kolla_internal_vip_address: "10.0.0.11"
kolla_external_vip_address: "10.0.0.11"

# Configure OpenStack release and base settings
openstack_release: "2025.1"
kolla_base_distro: "ubuntu"
kolla_install_type: "source"

# Disable High Availability
enable_haproxy: "no"
enable_keepalived: "no"
enable_mariadb_proxy: "no"
enable_proxysql: "no"
enable_rabbitmq_cluster: "no"

# Enable Core OpenStack Services
enable_keystone: "yes"
enable_glance: "yes"
enable_nova: "yes"
nova_compute_virt_type: "kvm"
enable_neutron: "yes"
enable_horizon: "yes"
enable_placement: "yes"
enable_cinder: "yes"

# Enable Additional Services
enable_heat: "yes"
enable_horizon_heat: "yes"
enable_skyline: "yes"

# Configure Cinder LVM Backend
enable_cinder_backend_lvm: "yes"

# Configure Designate
enable_designate: "yes"
neutron_dns_domain: "example.test."
neutron_dns_integration: "yes"
designate_backend: "bind9"
designate_ns_record: ["ns1.example.test"]
designate_enable_notifications_sink: "yes"
designate_forwarders_addresses: "8.8.8.8"
enable_horizon_designate: "yes"
EOF
echo "<---"

echo "---> Bootstraping the Server"
kolla-ansible bootstrap-servers -i all-in-one
echo "<---"

echo "---> Running Pre-Deployment Checks"
kolla-ansible prechecks -i all-in-one
echo "<---"

echo "---> Deploying OpenStack Services"
kolla-ansible deploy -i all-in-one
echo "<---"

echo "---> Post-Deployment Tasks"
kolla-ansible post-deploy -i all-in-one
echo "<---"

echo "---> Installing OpenStack CLI Client"
pip install python-openstackclient python-designateclient python-heatclient
echo "<---"

echo "---> Sourcing admin's openrc credentials file"
source /etc/kolla/admin-openrc.sh
echo "<---"

echo "---> Configuring Designate, Neutron and Nova for local DNS support"
openstack zone create --email admin@example.test example.test.
ZONE_ID=$(openstack zone show -f value -c id example.test.)
mkdir -p /etc/kolla/config/designate/
cat << EOF > /etc/kolla/config/designate/designate-sink.conf
[handler:nova_fixed]
zone_id = $ZONE_ID
[handler:neutron_floatingip]
zone_id = $ZONE_ID
EOF
kolla-ansible reconfigure -i all-in-one --tags designate,neutron,nova

echo "---> Updating netplan configuration with detected interfaces"
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
        addresses: [ 10.0.0.11 ]
        search: [ example.test ]
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
echo "<---"

cat << EOF

OpenStack All-in-One System is now deployed and ready for Lab configuration.

Horizon GUI Console is available from Windows browser at http://10.0.0.11
Skyline modern console is available from Windows browser at http://10.0.0.11:9999

User 'admin' password gets retrieved by running:

grep OS_PASSWORD /etc/kolla/admin-openrc.sh

Admin credentials for OpenStack CLI client are set by running:

source /etc/kolla/admin-openrc.sh

(Optionally shutdown the system now and take the VM snapshot in VMware Workstation Pro, restart the VM.)

Run lab-config.sh script to configure OpenStack Lab.
EOF
