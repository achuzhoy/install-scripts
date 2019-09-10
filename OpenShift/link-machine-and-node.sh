#!/bin/bash

source ../common/utils.sh

set -x
set -e

machine="$1"
node="$2"

if [ -z "$machine" -o -z "$node" ]; then
    echo "Usage: $0 MACHINE NODE"
    exit 1
fi

uid=$(echo $node | cut -f1 -d':')
node_name=$(echo $node | cut -f2 -d':')

# BEGIN Hack #260
# Hack workaround for openshift-metalkube/dev-scripts#260 until it's done automatically
# Also see https://github.com/metalkube/cluster-api-provider-baremetal/issues/49
oc --config ocp/auth/kubeconfig proxy &
proxy_pid=$!
function kill_proxy {
    kill $proxy_pid
}
trap kill_proxy EXIT SIGINT

HOST_PROXY_API_PATH="http://localhost:8001/apis/metal3.io/v1alpha1/namespaces/openshift-machine-api/baremetalhosts"

wait_for_json oc_proxy "${HOST_PROXY_API_PATH}" 10 -H "Accept: application/json" -H "Content-Type: application/json"

addresses=$(oc --config ocp/auth/kubeconfig get node -n openshift-machine-api ${node_name} -o json | jq -c '.status.addresses')

machine_data=$(oc --config ocp/auth/kubeconfig get machine -n openshift-machine-api -o json ${machine})
host=$(echo "$machine_data" | jq '.metadata.annotations["metal3.io/BareMetalHost"]' | cut -f2 -d/ | sed 's/"//g')

if [ -z "$host" ]; then
    echo "Machine $machine is not linked to a host yet." 1>&2
    exit 1
fi

# The address structure on the host doesn't match the node, so extract
# the values we want into separate variables so we can build the patch
# we need.
hostname=$(echo "${addresses}" | jq '.[] | select(. | .type == "Hostname") | .address' | sed 's/"//g')
ipaddr=$(echo "${addresses}" | jq '.[] | select(. | .type == "InternalIP") | .address' | sed 's/"//g')

host_patch='
{
  "status": {
    "hardware": {
      "hostname": "'${hostname}'",
      "nics": [
        {
          "ip": "'${ipaddr}'",
          "mac": "00:00:00:00:00:00",
          "model": "unknown",
          "speedGbps": 25,
          "vlanId": 0,
          "pxe": true,
          "name": "eno1"
        }
      ],
      "systemVendor": {
        "manufacturer": "Dell Inc.",
        "productName": "PowerEdge r640",
        "serialNumber": ""
      },
      "firmware": {
        "bios": {
          "date": "12/17/2018",
          "vendor": "Dell Inc.",
          "version": "1.6.13"
        }
      },
      "ramMebibytes": 0,
      "storage": [],
      "cpu": {
        "arch": "x86_64",
        "model": "Intel(R) Xeon(R) Gold 6138 CPU @ 2.00GHz",
        "clockMegahertz": 2000,
        "count": 40,
        "flags": []
      }
    }
  }
}
'

start_time=$(date +%s)
while true; do
    echo -n "Waiting for ${host} to stabilize ... "

    time_diff=$(($curr_time - $start_time))
    if [[ $time_diff -gt $timeout ]]; then
        echo "\nTimed out waiting for $name"
        return 1
    fi

    state=$(curl -s \
                 -X GET \
                 ${HOST_PROXY_API_PATH}/${host}/status \
                 -H "Accept: application/json" \
                 -H "Content-Type: application/json" \
                 -H "User-Agent: link-machine-and-node" \
                | jq '.status.provisioning.state' \
                | sed 's/"//g')
    echo "$state"
    if [ "$state" = "externally provisioned" ]; then
        break
    fi
    sleep 5
done

echo "PATCHING HOST"
echo "${host_patch}" | jq .

curl -s \
     -X PATCH \
     ${HOST_PROXY_API_PATH}/${host}/status \
     -H "Content-type: application/merge-patch+json" \
     -d "${host_patch}"

oc --config ocp/auth/kubeconfig get baremetalhost -n openshift-machine-api -o yaml "${host}"

