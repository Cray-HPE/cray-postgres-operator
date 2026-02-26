#!/bin/bash
#
# Script to add init container to all PostgreSQL clusters
# This fixes the RBD PVC permissions issue that causes postgres pods to randomly fail
#
# Usage: ./add-postgres-initcontainer.sh [namespace]
#        If namespace is not specified, it will patch all postgres clusters across all namespaces
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl command not found. Please install kubectl."
    exit 1
fi

# Check if jq is available
if ! command -v jq &> /dev/null; then
    print_warn "jq command not found. Some features may not work properly."
fi

# Parse arguments
NAMESPACE=""
if [ $# -gt 0 ]; then
    NAMESPACE="$1"
    print_info "Will only patch postgres clusters in namespace: $NAMESPACE"
else
    print_info "Will patch all postgres clusters across all namespaces"
fi

# Define the init container configuration
read -r -d '' INIT_CONTAINER_PATCH << 'EOF' || true
{
  "spec": {
    "initContainers": [
      {
        "name": "fix-pgdata-permissions",
        "image": "artifactory.algol60.net/csm-docker/stable/docker-kubectl:1.32.2",
        "command": [
          "sh",
          "-c",
          "echo \"Fixing permissions on /home/postgres/pgdata\"\nmkdir -p /home/postgres/pgdata\nchown -R 101:103 /home/postgres/pgdata\nchmod -R 0700 /home/postgres/pgdata\necho \"Permissions fixed successfully\"\n"
        ],
        "volumeMounts": [
          {
            "name": "pgdata",
            "mountPath": "/home/postgres/pgdata"
          }
        ],
        "securityContext": {
          "runAsUser": 0,
          "runAsNonRoot": false,
          "allowPrivilegeEscalation": true
        }
      }
    ]
  }
}
EOF

# Function to patch a single postgres cluster
patch_postgres_cluster() {
    local cluster_name="$1"
    local namespace="$2"
    
    print_info "Processing: $cluster_name in namespace $namespace"
    
    # Check if the cluster already has the init container
    if kubectl get postgresql "$cluster_name" -n "$namespace" -o json 2>/dev/null | grep -q "fix-pgdata-permissions"; then
        print_warn "  Init container already exists in $cluster_name, skipping"
        return 0
    fi
    
    # Apply the patch
    if kubectl patch postgresql "$cluster_name" -n "$namespace" --type=merge -p "$INIT_CONTAINER_PATCH" 2>/dev/null; then
        print_info "  ✓ Successfully patched $cluster_name"
        return 0
    else
        print_error "  ✗ Failed to patch $cluster_name"
        return 1
    fi
}

# Get list of postgres clusters
if [ -n "$NAMESPACE" ]; then
    # Get clusters in specific namespace
    CLUSTERS=$(kubectl get postgresql -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | .metadata.name + " " + .metadata.namespace')
else
    # Get clusters in all namespaces
    CLUSTERS=$(kubectl get postgresql --all-namespaces -o json 2>/dev/null | jq -r '.items[] | .metadata.name + " " + .metadata.namespace')
fi

if [ -z "$CLUSTERS" ]; then
    print_warn "No PostgreSQL clusters found"
    exit 0
fi

# Counter for statistics
TOTAL=0
SUCCESS=0
SKIPPED=0
FAILED=0

# Process each cluster
while IFS= read -r line; do
    if [ -z "$line" ]; then
        continue
    fi
    
    CLUSTER_NAME=$(echo "$line" | awk '{print $1}')
    CLUSTER_NS=$(echo "$line" | awk '{print $2}')
    
    ((TOTAL++))
    
    if patch_postgres_cluster "$CLUSTER_NAME" "$CLUSTER_NS"; then
        if kubectl get postgresql "$CLUSTER_NAME" -n "$CLUSTER_NS" -o json 2>/dev/null | grep -q "fix-pgdata-permissions"; then
            ((SUCCESS++))
        else
            ((SKIPPED++))
        fi
    else
        ((FAILED++))
    fi
done <<< "$CLUSTERS"

# Print summary
echo ""
echo "========================================"
echo "Summary:"
echo "========================================"
echo "Total clusters:     $TOTAL"
echo "Successfully patched: $SUCCESS"
echo "Already had fix:    $SKIPPED"
echo "Failed:             $FAILED"
echo "========================================"

# Provide next steps
echo ""
print_info "Next steps:"
echo "  1. Monitor the postgres pods to ensure they restart successfully"
echo "  2. Check the init container logs to verify permissions were fixed:"
echo "     kubectl logs <pod-name> -c fix-pgdata-permissions -n <namespace>"
echo "  3. Verify postgres pods are running:"
echo "     kubectl get pods -l application=spilo --all-namespaces"
echo ""

if [ $FAILED -gt 0 ]; then
    print_warn "Some clusters failed to patch. Please check the errors above."
    exit 1
fi

print_info "All clusters processed successfully!"
exit 0
