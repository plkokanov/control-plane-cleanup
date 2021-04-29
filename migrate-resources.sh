#!/bin/bash


# Copyright (c) 2019 SAP SE or an SAP affiliate company. All rights reserved. This file is licensed under the Apache Software License, v. 2 except as noted otherwise in the LICENSE file.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

namespace=shoot--mig--migration2

# Delete BackupEntrys
backupentry=$(kubectl get backupentry -o jsonpath='{.items[*].metadata.name}' | grep ${namespace})
echo "Deleting backupentry: $backupentry"
kubectl annotate backupentry "${backupentry}" 'confirmation.gardener.cloud/deletion=true' --overwrite=true
kubectl delete backupentry "${backupentry}"

# Annotate extension resources for migration
extension_resource_kinds=("ContainerRuntime" "ControlPlane" "Extension" "Infrastructure" "Network" "OperatingSystemConfig" "Worker")
for resource_kind in "${extension_resource_kinds[@]}"; do
    kubectl -n "${namespace}" annotate "${resource_kind}" --all 'gardener.cloud/operation=migrate' --overwrite=true
done


# Wait until extension resources migrated
for resource_kind in "${extension_resource_kinds[@]}"; do
    count=0
    while true; do
        lastOperation=$(kubectl -n "${namespace}" get "${resource_kind}" -o jsonpath='{range .items[*]}{@.status.lastOperation.type}{" "}{@.status.lastOperation.state}{"\n"}{end}')
        if [[ -z "$lastOperation" ]] || [[ "$lastOperation" =~ "Migrate Succeeded" ]]; then
            echo "Extension resource $resource_kind migrated successfully"
            break
        fi
        echo "Migrate operation for $resource_kind is not ready yet. Current lastOperation is: $lastOperation"
        sleep 30
        ((++count))
        if [ "$count" -gt 6 ]; then
            echo "Timeout while waiting for $resource_kind to be migrated"
            exit 1
        fi
    done
done

# Delete all Extension resources
for resource_kind in "${extension_resource_kinds[@]}"; do
    # read -r -d '' -a resources < <(kubectl -n "${namespace}" get "${resource_kind}" -o jsonpath='{.items[*].metadata.name}')
        # for resource in "${resources[@]}"; do
    #     kubectl -n "${namespace}" patch "${resource_kind}" "${resource}" --type=merge --patch='{"metadata":{"finalizers": [null]}}'
    # doneku
    echo "Deleting extension resource_kind $resource_kind"
    kubectl -n "${namespace}" annotate "${resource_kind}" --all 'confirmation.gardener.cloud/deletion=true'
    kubectl -n "${namespace}" delete "${resource_kind}" --all
done

# Delete all ManagedResources
read -r -d '' -a managed_resources < <( kubectl -n "${namespace}" get managedresource -o jsonpath='{.items[*].metadata.name}' && printf '\0' )
for resource in "${managed_resources[@]}"; do
    echo "Setting KeepObjects to true on $resource"
    kubectl -n "${namespace}" patch managedresource "${resource}" --type=merge --patch='{"spec":{"keepObjects":true}}'
    echo "Deleting managed resource: $resource"
    kubectl -n "${namespace}" delete managedresource "${resource}" --wait=false
    echo "Removing finalizer on resource $resource"
    kubectl -n "${namespace}" patch managedresource "${resource}" --type=merge --patch='{"metadata":{"finalizers": [null]}}'
done


# Migrate DNS
echo "Deleting dns owners"
kubectl -n "${namespace}" delete dnsowners --all

echo "Deleting dns entries"
kubectl -n "${namespace}" delete dnsentries --all

echo "Deleting dns owners"
kubectl -n "${namespace}" delete dnsproviders --all


# Delete Namespace
echo "Deleting namespace"
kubectl delete ns "${namespace}"

# Delete ClusterResource
echo "Deleting Cluster resource"
kubectl delete cluster "${namespace}"