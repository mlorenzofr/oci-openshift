#!/usr/bin/env bash

set -e
set -x

if [ ! -d "/sys/firmware/ibft" ]
then
  echo "No IBFT configuration found. Skipping."
  exit 0
fi

MTU=9000
NODEIP_CONF="/etc/systemd/system/kubelet.service.d/30-oci-nodeip.conf"

function get_if_name_from_mac_address {
  mac_address="${1}"
  ip -json link | jq --raw-output --arg mac_address "${mac_address}" '. | map(select(.address==($mac_address|ascii_downcase))) | .[0].ifname'
}

# Get the primary interface used for the default route
function get_primary_if_name {
  ip -json route show default | jq --raw-output '.[] | select(.dst == "default") | .dev' | head -n1
}

# Extract the prefix from the primary interface name
function extract_prefix {
  primary_if_name="${1}"
  if [[ "${primary_if_name}" =~ ^([a-zA-Z]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Get the secondary interface name based on the dynamic prefix
function get_secondary_if_name_by_prefix {
  prefix="${1}"
  all_interfaces=$(ip -json link show | jq --raw-output '.[].ifname')

  for ifname in ${all_interfaces}; do
    if [[ "${ifname}" == "${prefix}"* && "${ifname}" != "${primary_if_name}" ]]; then
      echo "${ifname}"
      return 0
    fi
  done

  echo "No secondary interface found with the prefix ${prefix}."
  return 1
}

# Ensure OCI DNS is configured on a given network connection
function set_oci_dns {
  local conn_name="$1"
  dns_value=$(nmcli -g ipv4.dns connection show "$conn_name")
  if [[ -z "$dns_value" || "$dns_value" == "--" ]]; then
    echo "Setting OCI DNS for $conn_name"
    nmcli connection modify "$conn_name" ipv4.dns "169.254.169.254"
    nmcli connection modify "$conn_name" ipv4.ignore-auto-dns no
    nmcli connection up "$conn_name"
  fi
}

# Convert the primary interface from DHCP to static configuration
# This prevents losing network connectivity during ostree switch-root
# Uses a zero-downtime approach by modifying the connection without bringing it down
function convert_primary_to_static {
  local if_name="$1"
  local ip_address gateway subnet_size mtu conn_name conn_uuid current_method

  echo "Converting primary interface ${if_name} from DHCP to static configuration"

  # Get current IP address and prefix length
  ip_address=$(ip -json addr show dev "${if_name}" | jq -r '.[0].addr_info[] | select(.family=="inet") | .local')
  subnet_size=$(ip -json addr show dev "${if_name}" | jq -r '.[0].addr_info[] | select(.family=="inet") | .prefixlen')

  # Get default gateway
  gateway=$(ip -json route show default | jq -r --arg dev "${if_name}" '.[] | select(.dev==$dev) | .gateway')

  # Get current MTU
  mtu=$(ip -json link show dev "${if_name}" | jq -r '.[0].mtu')

  if [[ -z "${ip_address}" || -z "${subnet_size}" || -z "${gateway}" ]]; then
    echo "ERROR: Failed to retrieve network configuration from ${if_name}"
    echo "IP: ${ip_address}, Subnet: ${subnet_size}, Gateway: ${gateway}"
    return 1
  fi

  echo "Captured configuration - IP: ${ip_address}/${subnet_size}, Gateway: ${gateway}, MTU: ${mtu}"

  # Find the active connection UUID for this interface
  conn_uuid=$(nmcli -t -f DEVICE,UUID connection show --active | grep "^${if_name}:" | cut -d: -f2)

  if [[ -n "${conn_uuid}" ]]; then
    # Get the connection name
    conn_name=$(nmcli -t -f UUID,NAME connection show | grep "^${conn_uuid}:" | cut -d: -f2)
    current_method=$(nmcli -t -f ipv4.method connection show "${conn_uuid}" | cut -d: -f2)

    echo "Found active connection: ${conn_name} (${conn_uuid}), method: ${current_method}"

    # Check if already configured as static
    if [[ "${current_method}" == "manual" ]]; then
      echo "Primary interface ${if_name} is already configured with static IP"
      return 0
    fi

    # Modify the existing connection in-place (zero downtime)
    echo "Modifying connection ${conn_name} to static configuration (zero downtime)"
    nmcli connection modify "${conn_uuid}" ipv4.method manual
    nmcli connection modify "${conn_uuid}" ipv4.addresses "${ip_address}/${subnet_size}"
    nmcli connection modify "${conn_uuid}" ipv4.gateway "${gateway}"
    nmcli connection modify "${conn_uuid}" ipv4.dns "169.254.169.254"
    nmcli connection modify "${conn_uuid}" ipv4.ignore-auto-dns no
    nmcli connection modify "${conn_uuid}" ethernet.mtu "${mtu}"
    nmcli connection modify "${conn_uuid}" ipv4.route-metric 100
    nmcli connection modify "${conn_uuid}" connection.autoconnect true

    # Reapply the connection without bringing the interface down
    # This applies the new settings while maintaining connectivity
    nmcli device reapply "${if_name}"

    echo "Primary interface ${if_name} successfully converted to static configuration (no downtime)"
  else
    # No active connection found, create a new one
    # This path should rarely execute in a running system
    echo "No active connection found, creating new static connection"

    nmcli connection add con-name "${if_name}" ifname "${if_name}" type ethernet \
      ip4 "${ip_address}/${subnet_size}" gw4 "${gateway}"

    nmcli connection modify "${if_name}" ipv4.dns "169.254.169.254"
    nmcli connection modify "${if_name}" ipv4.ignore-auto-dns no
    nmcli connection modify "${if_name}" ethernet.mtu "${mtu}"
    nmcli connection modify "${if_name}" connection.autoconnect true
    nmcli connection modify "${if_name}" ipv4.route-metric 100

    # Bring up the new connection
    nmcli connection up "${if_name}"

    echo "Primary interface ${if_name} configured with new static connection"
  fi

  return 0
}

# /opc/v2/vnics endpoint returns something that will look like the following
# structure:
# [
#   {
#     "macAddr": "00:10:e0:ec:72:fc",
#     "nicIndex": 0,
#     "privateIp": "10.0.29.201",
#     "subnetCidrBlock": "10.0.16.0/20",
#     "virtualRouterIp": "10.0.16.1",
#     "vlanTag": 0,
#     "vnicId": "ocid1.vnic.oc1.us-sanjose-1.abzwuljrppq34sbvgltddp7wujxwqw6xb7zjkwg54oaewx5mc4wr5cgtdzna"
#   },
#   {
#     "macAddr": "00:10:e0:ec:72:fd",
#     "nicIndex": 1,
#     "privateIp": "10.0.32.210",
#     "subnetCidrBlock": "10.0.32.0/20",
#     "virtualRouterIp": "10.0.32.1",
#     "vlanTag": 0,
#     "vnicId": "ocid1.vnic.oc1.us-sanjose-1.abzwuljrsndaptsyq5mppfsoaqoun3gbvnpngcaspybo2nbpcmrozx25jenq"
#   }
# ]

# Fetch the VNICS data
vnics=$(curl --silent -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/vnics/)

# Get primary interface information
primary_if_name=$(get_primary_if_name)
echo "Primary interface: ${primary_if_name}"

# Convert primary interface from DHCP to static to survive ostree switch-root
if [[ -n "${primary_if_name}" ]]; then
  convert_primary_to_static "${primary_if_name}"
else
  echo "WARNING: Could not determine primary interface name"
fi

# Get secondary interface information
secondary_if_mac_address=$(jq -r '.[1].macAddr' <<< "${vnics}")
secondary_if_ip_address=$(jq -r '.[1].privateIp' <<< "${vnics}")
secondary_if_vlan_tag=$(jq -r '.[1].vlanTag' <<< "${vnics}")
secondary_if_default_gateway=$(jq -r '.[1].virtualRouterIp' <<< "${vnics}")
secondary_if_subnet=$(jq -r '.[1].subnetCidrBlock' <<< "${vnics}")
secondary_if_subnet_size=$(cut -f 2 -d '/' <<< "${secondary_if_subnet}")
secondary_if_name=$(get_if_name_from_mac_address "${secondary_if_mac_address}")

# If the interface name is null or empty, fallback to using the IP address
if [[ -z "${secondary_if_name}" || "${secondary_if_name}" == "null" ]]; then
  echo "MAC address not found, falling back to prefix lookup method."
  primary_if_name=$(get_primary_if_name)
  prefix=$(extract_prefix "${primary_if_name}")
  secondary_if_name=$(get_secondary_if_name_by_prefix "${prefix}")
  if [ "${secondary_if_vlan_tag}" -ne 0 ]; then
    echo "VLAN Tag is not 0, network configuration needs to be modified at the VLAN level"
    if [ ! -f "/etc/NetworkManager/system-connections/${secondary_if_name}.nmconnection" ]; then
        nmcli connection add type vlan con-name "${secondary_if_name}.${secondary_if_vlan_tag}" ifname "${secondary_if_name}.${secondary_if_vlan_tag}" dev "${secondary_if_name}" id "${secondary_if_vlan_tag}" ip4 "${secondary_if_ip_address}/${secondary_if_subnet_size}" gw4 "${secondary_if_default_gateway}"
        nmcli connection modify "${secondary_if_name}.${secondary_if_vlan_tag}" 802-3-ethernet.cloned-mac-address "${secondary_if_mac_address}"
        nmcli connection modify "${secondary_if_name}.${secondary_if_vlan_tag}" 802-3-ethernet.mtu ${MTU}
        nmcli connection modify "${secondary_if_name}.${secondary_if_vlan_tag}" ipv4.route-metric 0 # make this interface the default interface
        nmcli connection modify "${secondary_if_name}.${secondary_if_vlan_tag}" connection.autoconnect true
        nmcli connection reload
        nmcli connection up "${secondary_if_name}.${secondary_if_vlan_tag}"
        # Remove the ens340np0 connection
        for uuid in $(nmcli -t -f UUID,DEVICE connection show | grep ':--' | cut -d: -f1); do
          nmcli connection delete "$uuid"
        done
        set_oci_dns "${secondary_if_name}.${secondary_if_vlan_tag}"
    fi
  else
    # Create a standard Ethernet connection if VLAN_ID is 0
    if [ ! -f "/etc/NetworkManager/system-connections/${secondary_if_name}.nmconnection" ]; then
      nmcli connection add con-name "${secondary_if_name}" ifname "${secondary_if_name}" type ethernet ip4 "${secondary_if_ip_address}/${secondary_if_subnet_size}" gw4 "${secondary_if_default_gateway}"
      nmcli connection modify "${secondary_if_name}" ethernet.mtu ${MTU}
      nmcli connection modify "${secondary_if_name}" ipv4.route-metric 0 # make this interface the default interface
      nmcli connection modify "${secondary_if_name}" connection.autoconnect true
      nmcli connection reload
      nmcli connection up "${secondary_if_name}"
      set_oci_dns "${secondary_if_name}"
    fi
  fi
else
  # Create a standard Ethernet connection by default
  if [ ! -f "/etc/NetworkManager/system-connections/${secondary_if_name}.nmconnection" ]; then
    nmcli connection add con-name "${secondary_if_name}" ifname "${secondary_if_name}" type ethernet ip4 "${secondary_if_ip_address}/${secondary_if_subnet_size}" gw4 "${secondary_if_default_gateway}"
    nmcli connection modify "${secondary_if_name}" ethernet.mtu ${MTU}
    nmcli connection modify "${secondary_if_name}" ipv4.route-metric 0 # make this interface the default interface
    nmcli connection modify "${secondary_if_name}" connection.autoconnect true
    nmcli connection reload
    nmcli connection up "${secondary_if_name}"
    set_oci_dns "${secondary_if_name}"
  fi
fi

# Don't proceed further if we run in the discovery environment
if [ -n "${ASSISTED_INSTALLER_DISCOVERY_ENV}" ]
then
  exit 0
fi

# Force the kubelet to use the IP of the secondary VNIC for as node IP
# This is required because the kubelet has several ways to determine it, and
# may not use the right IP. Not using the right IP may can cause issues with
# etcd.
if [ ! -f "${NODEIP_CONF}" ]
then
  cat << EOF > "${NODEIP_CONF}"
[Service]
Environment="KUBELET_NODE_IP=${secondary_if_ip_address}"
EOF
fi
