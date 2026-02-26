#!/bin/bash
#
# Quick test script to verify the init container configuration
# This can be used to test the fix on a single postgres cluster before rolling out everywhere
#
# Usage: ./test-initcontainer.sh <cluster-name> <namespace>
# Example: ./test-initcontainer.sh cray-smd-postgres services
#

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <cluster-name> <namespace>"
    echo "Example: $0 cray-smd-postgres services"
    exit 1
fi

CLUSTER_NAME="$1"
NAMESPACE="$2"

echo "=========================================="
echo "Testing Init Container on $CLUSTER_NAME"
echo "=========================================="
echo ""

# Check if cluster exists
if ! kubectl get postgresql "$CLUSTER_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "ERROR: PostgreSQL cluster $CLUSTER_NAME not found in namespace $NAMESPACE"
    exit 1
fi

echo "✓ Found PostgreSQL cluster: $CLUSTER_NAME in namespace $NAMESPACE"
echo ""

# Get current pod names
echo "Current pods:"
kubectl get pods -n "$NAMESPACE" -l "application=spilo,cluster-name=$CLUSTER_NAME"
echo ""

# Apply the init container patch
echo "Applying init container patch..."
kubectl patch postgresql "$CLUSTER_NAME" -n "$NAMESPACE" --type=merge -p '{
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
}'

echo ""
echo "✓ Init container patch applied successfully"
echo ""

# Wait for pods to be recreated
echo "Waiting for pods to be recreated with init container..."
sleep 5

# Show new pods
echo ""
echo "Updated pods:"
kubectl get pods -n "$NAMESPACE" -l "application=spilo,cluster-name=$CLUSTER_NAME"
echo ""

# Get one pod name for testing
POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l "application=spilo,cluster-name=$CLUSTER_NAME" -o jsonpath='{.items[0].metadata.name}')

if [ -z "$POD_NAME" ]; then
    echo "WARNING: No pods found yet. They may still be starting up."
    echo "Run these commands manually to check:"
    echo "  kubectl get pods -n $NAMESPACE -l application=spilo,cluster-name=$CLUSTER_NAME"
    exit 0
fi

# Wait for pod to be running
echo "Waiting for pod $POD_NAME to be ready..."
kubectl wait --for=condition=ready pod/"$POD_NAME" -n "$NAMESPACE" --timeout=120s || {
    echo "WARNING: Pod didn't become ready within 120 seconds"
    echo "Check pod status with: kubectl describe pod $POD_NAME -n $NAMESPACE"
}

echo ""
echo "=========================================="
echo "Verification Tests"
echo "=========================================="
echo ""

# Test 1: Check init container logs
echo "1. Init container logs:"
echo "   (This should show the permission fix messages)"
echo ""
kubectl logs "$POD_NAME" -c fix-pgdata-permissions -n "$NAMESPACE" || {
    echo "   (Init container logs not available - pod may not have restarted yet)"
}
echo ""

# Test 2: Verify permissions
echo "2. Verifying permissions on /home/postgres/pgdata:"
echo "   (Should show: drwx------ ... postgres postgres ... pgdata)"
echo ""
kubectl exec "$POD_NAME" -n "$NAMESPACE" -c postgres -- ls -la /home/postgres/ | grep pgdata || {
    echo "   (Unable to check permissions - postgres may not be ready yet)"
}
echo ""

# Test 3: Check postgres is running
echo "3. Checking postgres status:"
kubectl exec "$POD_NAME" -n "$NAMESPACE" -c postgres -- patronictl list || {
    echo "   (Patroni not ready yet - wait a bit longer)"
}
echo ""

echo "=========================================="
echo "Test Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Monitor the cluster for a few minutes to ensure stability"
echo "  2. Check all pods in the cluster have restarted successfully:"
echo "     kubectl get pods -n $NAMESPACE -l application=spilo,cluster-name=$CLUSTER_NAME"
echo "  3. Verify no permission errors in postgres logs:"
echo "     kubectl logs $POD_NAME -n $NAMESPACE -c postgres | tail -20"
echo "  4. If everything looks good, roll out to other clusters using:"
echo "     ./add-postgres-initcontainer.sh"
echo ""
