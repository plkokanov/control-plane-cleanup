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


# This script can be used to clean up the orphaned control plane of a `Shoot` cluster
# after it has been forceefully migrated to a different `Seed`. Make sure that the
# kubeconfig you use points to the `Seed` that hosts the orphaned control plane and not
# the `Seed` that is currently hosting the active control plane of the `Shoot` cluster.

### FUNCTIONS ###

function print_usage() {
  cat <<EOF
ops-pod: Clean up an orphaned control plane of a Shoot cluster after it has been forcefully migrated to a different seed.
Usage:
  clean-up-resources <--namespace|-n> [--kubeconfig|-k]
Options:
  -n|--namespace    The namespace used for the Shoot's control plane. Resources will be removed from it and eventually the namespace
                    will be deleted up as well.
  -k|--kubeconfig   Path to the kubeconfig that will be used when deleting resources. It should point to the Seed cluster that is currently
                    hosting the orphaned control plane of the Shoot cluster. By default the KUBECONFIG environmnet variable is used.
  -r|--resources    A comma separated array of resources to delete and remove their finalizers. If this flag is specified, nothing else will
                    be cleaned up from the shoot namespace.
EOF
}

function delete_resource() {
    local resource_namespace="$1"
    local resource_kind="$2"
    local resource_name="$3"

    if [[ -z ${resource_kind} ]]; then
        echo "Resource kind cannot be empty when deleting ${resource_namespace}/${resource_kind}"
        exit 1
    fi

    if [[ -z ${resource_name} ]]; then
        echo "Resource name or '--all' has to be specified when deleting ${resource_namespace}/${resource_kind}"
        exit 1
    fi

    kubectl --kubeconfig="${kubeconfig}" --namespace="${resource_namespace}" annotate "${resource_kind}" "${resource_name}" 'confirmation.gardener.cloud/deletion=true' --overwrite=true
    kubectl --kubeconfig="${kubeconfig}" --namespace="${resource_namespace}" delete "${resource_kind}" "${resource_name}" --wait=false
    echo "Deleted $resource_kind/$resource_name in $resource_namespace"
}

function shallow_delete_resource() {
    local resource_namespace="$1"
    local resource_kind="$2"
    local resource_name="$3"

    if [[ -z ${resource_kind} ]]; then
        echo "Resource kind cannot be empty when shallow deleting ${resource_namespace}/${resource_kind}"
        exit 1
    fi

    if [[ -z ${resource_name} ]]; then
        echo "Resource name or '--all' has to be specified when shallow deleting ${resource_namespace}/${resource_kind}"
        exit 1
    fi

    if [[ "${resource_name}" == "--all" ]]; then
        read -r -d '' -a resources_of_kind < <( kubectl --kubeconfig="${kubeconfig}" --namespace="${resource_namespace}" get "${resource_kind}" -o jsonpath='{.items[*].metadata.name}' && printf '\0' )
        for resource_of_kind in "${resources_of_kind[@]}"; do
            shallow_delete_resource "${resource_namespace}" "${resource_kind}" "${resource_of_kind}"
        done
        return
    fi

    echo "Shallow deletion of $resource_kind/$resource_name in $resource_namespace ..."
    kubectl --kubeconfig="${kubeconfig}" --namespace="${resource_namespace}" annotate "${resource_kind}" "${resource_name}" 'confirmation.gardener.cloud/deletion=true' --overwrite=true
    kubectl --kubeconfig="${kubeconfig}" --namespace="${resource_namespace}" patch "${resource_kind}" "${resource_name}" --type=merge --patch='{"metadata":{"finalizers": []}}'
    kubectl --kubeconfig="${kubeconfig}" --namespace="${resource_namespace}" delete "${resource_kind}" "${resource_name}" --wait=false
}

function migrate_resource() {
    local resource_namespace="$1"
    local resource_kind="$2"
    local resource_name="$3"

    if [[ -z ${resource_kind} ]]; then
        echo "Resource kind cannot be empty when migrating ${resource_namespace}/${resource_kind}"
        exit 1
    fi

    if [[ -z ${resource_name} ]]; then
        echo "Resource name or '--all' has to be specified when migrating ${resource_namespace}/${resource_kind}"
        exit 1
    fi

    kubectl --kubeconfig="${kubeconfig}" -n "${namespace}" annotate "${resource_kind}" "${resource_name}" 'gardener.cloud/operation=migrate' --overwrite=true
}

function wait_for_migration() {
    local resource_namespace=$1
    local resource_kind=$2
    local resource_name=$3

    if [[ "${resource_name}" == "--all" ]]; then
        read -r -d '' -a resources_of_kind < <( kubectl --kubeconfig="${kubeconfig}" -n "${resource_namespace}" get "${resource_kind}" -o jsonpath='{.items[*].metadata.name}' && printf '\0' )
        for resource_of_kind in "${resources_of_kind[@]}"; do
            wait_for_migration "${resource_namespace}" "${resource_kind}" "${resource_of_kind}"
        done
        return
    fi

    count=0
    while true; do
        lastOperation=$(kubectl --kubeconfig="${kubeconfig}" -n "${resource_namespace}" get "${resource_kind}" "${resource_name}" -o jsonpath='{.status.lastOperation.type}{" "}{.status.lastOperation.state}')
        if [[ -z "$lastOperation" ]] || [[ "$lastOperation" =~ "Migrate Succeeded" ]]; then
            echo "Extension resource $resource_kind/$resource_name in $resource_namespace migrated successfully"
            break
        fi
        echo "Migrate operation for $resource_kind/$resource_name in $resource_namespace is not ready yet. Current lastOperation is: $lastOperation"
        sleep 30
        ((++count))
        if [ "$count" -gt 6 ]; then
            echo "Timeout while waiting for$resource_kind/$resource_name in $resource_namespace to be migrated"
            exit 1
        fi
    done
}

function wait_for_deletion() {
    local resource_namespace="$1"
    local resource_kind="$2"
    local resource_name="$3"

     if [[ "${resource_name}" == "--all" ]]; then
        read -r -d '' -a resources_of_kind < <( kubectl --kubeconfig="${kubeconfig}" -n "${resource_namespace}" get "${resource_kind}" -o jsonpath='{.items[*].metadata.name}' && printf '\0' )
        for resource_of_kind in "${resources_of_kind[@]}"; do
            wait_for_deletion "${resource_namespace}" "${resource_kind}" "${resource_of_kind}"
        done
        return
    fi

    count=0
    while true; do
        remainingResources=$(kubectl --kubeconfig="${kubeconfig}" -n "${resource_namespace}" get "${resource_kind}" "${resource_name}" -o jsonpath='{.metadata.name}')
        if [[ -z "$remainingResources" ]] || [[ "$remainingResources" =~ "NotFound" ]]; then
            echo "Extension resource $resource_kind/$resource_name in $resource_namespace deleted successfully"
            break
        fi
        echo "Delete operation for $resource_kind/$resource_name in $resource_namespace is not ready yet."
        sleep 30
        ((++count))
        if [ "$count" -gt 6 ]; then
            echo "Timeout while waiting for $resource_kind/$resource_name in $resource_namespace to be deleted"
            exit 1
        fi
    done
}

### END FUNCTIONS

namespace=""
kubeconfig=""
resource_kinds_for_shallow_deletion=()

while [[ $# -gt 0 ]]; do
  key="${1}"
  case ${key} in
    -n|--namespace)
      namespace="${2}"
      shift
      shift
      ;;
    -k|--kubeconfig)
      kubeconfig="${2}"
      shift
      shift
      ;;
    -r|--resources)
      IFS=',' read -r -a resource_kinds_for_shallow_deletion <<< "${2}"
      shift
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown flag: ${1}"
      print_usage
      exit 1
  esac
done

if [[ -z ${namespace} ]]; then
    echo "Error: namespace flag must be specified"
    print_usage
    exit 1
fi

if [[ ${#resource_kinds_for_shallow_deletion[@]} -gt 0 ]]; then
    echo "Specified a list of resources to delete. Cleaning them up..."
    for resource_kind_to_delete in "${resource_kinds_for_shallow_deletion[@]}"; do
        shallow_delete_resource "$namespace" "$resource_kind_to_delete" "--all"
    done
    echo "Resources have been deleted."
    exit 0
fi

cluster_resource=$(kubectl --kubeconfig="${kubeconfig}" get cluster "${namespace}" -o jsonpath='{.metadata.name}')

# Delete BackupEntries
backupentry=$(kubectl --kubeconfig="${kubeconfig}" get backupentry -o jsonpath='{range .items[*]}{@.metadata.name}{"\n"}{end}}' | grep "${namespace}")
if [[ -n "${backupentry}" ]]; then
    delete_resource "" "BackupEntry" "${backupentry}" "--all"
fi

# Annotate extension resources for migration
extension_resource_kinds=("ContainerRuntime" "ControlPlane" "Extension" "Infrastructure" "Network" "OperatingSystemConfig" "Worker" "DNSRecord")
for resource_kind in "${extension_resource_kinds[@]}"; do
    migrate_resource "${namespace}" "${resource_kind}" "--all"
done

if [[ -n ${cluster_resource} ]]; then
    # Wait until extension resources migrated
    for resource_kind in "${extension_resource_kinds[@]}"; do
        wait_for_migration "${namespace}" "${resource_kind}" "--all"
    done
fi


# Delete all Extension resources
for resource_kind in "${extension_resource_kinds[@]}"; do
    if [[ -z ${cluster_resource} ]]; then
        shallow_delete_resource "${namespace}" "${resource_kind}" "--all"
    else
        delete_resource "${namespace}" "${resource_kind}" "--all"
    fi
done

# Wait for deletion of Extension resources
for resource_kind in "${extension_resource_kinds[@]}"; do
    wait_for_deletion "${namespace}" "${resource_kind}" "--all"
done

if [[ -z ${cluster_resource} ]]; then
    # Delete all secrets if cluster resource not found
    shallow_delete_resource "${namespace}" "secret" "--all"
    wait_for_deletion "${namespace}" "secret" "--all"

    # Delete all configmaps if cluster resource not found
    shallow_delete_resource "${namespace}" "configmap" "--all"
    wait_for_deletion "${namespace}" "configmap" "--all"
fi


# Delete all ManagedResources
read -r -d '' -a managed_resources < <( kubectl -n "${namespace}" get managedresource -o jsonpath='{.items[*].metadata.name}' && printf '\0' )
for resource in "${managed_resources[@]}"; do
    echo "Setting KeepObjects to true on $resource"
    kubectl -n "${namespace}" patch managedresource "${resource}" --type=merge --patch='{"spec":{"keepObjects":true}}'
    delete_resource "${namespace}" managedresource "${resource}"
    wait_for_deletion "${namespace}" managedresource "${resource}"
done

# Delete ETCD Druid
delete_resource "${namespace}" etcd etcd-events
delete_resource "${namespace}" etcd etcd-main

# Delete DNS
dns_owner=$(kubectl get dnsowner -o jsonpath='{range .items[*]}{@.metadata.name}{"\n"}{end}}' | grep ${namespace})
if [[ -n ${dns_owner} ]]; then
delete_resource "" dnsowner "${dns_owner}"
fi

echo "Deleting dns entries"
delete_resource "${namespace}" dnsentries "--all"

echo "Deleting dns providers"
delete_resource "${namespace}" dnsproviders "--all"

# Delete Namespace
echo "Deleting namespace"
kubectl delete ns "${namespace}"

# Delete ClusterResource
echo "Deleting Cluster resource"
kubectl delete cluster "${namespace}"