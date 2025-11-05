#!/bin/bash

# Redis Sentinel Benchmark Script
# Usage: ./run-benchmark.sh

set -e

NAMESPACE="redis-sentinel"
JOB_NAME="redis-benchmark"

echo "================================"
echo "Redis Sentinel Benchmark Test"
echo "================================"
echo ""

# Check if Redis is ready
echo "⏳ Checking Redis cluster status..."
READY_PODS=$(kubectl get pods -n $NAMESPACE -l app=redis --no-headers 2>/dev/null | grep "Running" | wc -l)

if [ $READY_PODS -lt 3 ]; then
    echo "❌ ERROR: Redis cluster not ready ($READY_PODS/3 pods running)"
    exit 1
fi

echo "✅ Redis cluster ready: $READY_PODS/3 pods running"
echo ""

# Delete existing benchmark job if any
echo "🧹 Cleaning up previous benchmark jobs..."
kubectl delete job $JOB_NAME -n $NAMESPACE --ignore-not-found=true >/dev/null 2>&1
sleep 2

# Deploy benchmark job
echo "🚀 Starting benchmark job (4 pods, 2 threads, 10 connections each)..."
kubectl apply -f 06-benchmark-job.yaml

echo ""
echo "⏳ Waiting for benchmark pods to start..."
sleep 5

# Show configuration
echo ""
echo "📊 Benchmark Configuration:"
echo "  - Pods: 4 (parallel)"
echo "  - Threads per pod: 2"
echo "  - Connections per thread: 10"
echo "  - Total connections: 80 (4 pods x 2 threads x 10 conns)"
echo "  - Test duration: 2 minutes (120 seconds)"
echo "  - Ratio: 50% SET, 50% GET (1:1)"
echo "  - Data size: 256 bytes"
echo ""

echo "📈 Monitoring benchmark progress..."
echo "Press Ctrl+C to stop monitoring (job will continue running)"
echo ""

# Monitor job status
START_TIME=$(date +%s)
while true; do
    JOB_STATUS=$(kubectl get job $JOB_NAME -n $NAMESPACE -o json 2>/dev/null || echo "{}")
    
    ACTIVE=$(echo $JOB_STATUS | jq -r '.status.active // 0')
    SUCCEEDED=$(echo $JOB_STATUS | jq -r '.status.succeeded // 0')
    FAILED=$(echo $JOB_STATUS | jq -r '.status.failed // 0')
    
    ELAPSED=$(($(date +%s) - START_TIME))
    
    printf "\r[${ELAPSED}s] Running: $ACTIVE | Completed: $SUCCEEDED/4 | Failed: $FAILED"
    
    if [ "$SUCCEEDED" -eq 4 ]; then
        echo ""
        echo ""
        echo "✅ Benchmark completed successfully!"
        break
    fi
    
    if [ "$FAILED" -gt 0 ]; then
        echo ""
        echo ""
        echo "⚠️  WARNING: Some pods failed!"
        break
    fi
    
    sleep 2
done

echo ""
echo "================================"
echo "📊 Benchmark Results"
echo "================================"
echo ""

# Get pod names
PODS=$(kubectl get pods -n $NAMESPACE -l app=redis-benchmark -o json | jq -r '.items[].metadata.name')

echo "📥 Collecting results from pods..."
echo ""

for POD in $PODS; do
    echo "=== Results from $POD ==="
    
    # Get logs from completed pod
    kubectl logs $POD -n $NAMESPACE 2>/dev/null | grep -E "Totals|Type|GET|SET|Ops/sec|Hits/sec|Latency" || echo "No logs available"
    
    echo ""
done

echo ""
echo "📋 Benchmark Summary Commands:"
echo "  kubectl logs -l app=redis-benchmark -n $NAMESPACE --tail=50"
echo "  kubectl get job $JOB_NAME -n $NAMESPACE"
echo ""

echo "🗑️  To delete benchmark job:"
echo "  kubectl delete job $JOB_NAME -n $NAMESPACE"
echo ""
