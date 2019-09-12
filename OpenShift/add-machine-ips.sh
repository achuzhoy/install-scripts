#!/bin/bash
set -x
set -e

export CLUSTER_NAME=$(hostname -f | cut -d'.' -f 2)

for node in $(oc --config ocp/auth/kubeconfig get nodes -o template --template='{{range .items}}{{.metadata.uid}}:{{.metadata.name}}{{"\n"}}{{end}}'); do
    node_name=$(echo $node | cut -f2 -d':')
    machine_name=$CLUSTER_NAME-$(echo $node_name | grep -oE "(master|worker)-[0-9]+")
    if [[ "$machine_name" == *"worker"* ]]; then
        echo "Skipping worker $machine_name because it should have inspection data to link automatically"
        continue
    fi
    ./link-machine-and-node.sh "$machine_name" "$node"
done
