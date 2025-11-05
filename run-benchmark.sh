#!/bin/bash

# Redis Sentinel Dual-Backend Benchmark Script
# Tests write (master) and read (replicas) separately

set -e

NAMESPACE="redis-sentinel"
WRITE_JOB="redis-benchmark-write"
READ_JOB="redis-benchmark-read"

echo "============================================"
echo "Redis Sentinel Dual-Backend Benchmark"
echo "============================================"
echo ""

# Check if cluster is ready
echo "⏳ Checking cluster status..."
REDIS_READY=$(kubectl get pods -n $NAMESPACE -l app=redis --no-headers 2>/dev/null | grep "Running" | wc -l)
HAPROXY_READY=$(kubectl get pods -n $NAMESPACE -l app=haproxy --no-headers 2>/dev/null | grep "2/2.*Running" | wc -l)

if [ $REDIS_READY -lt 3 ]; then
    echo "[ERROR] Redis cluster not ready ($REDIS_READY/3 pods)"
    exit 1
fi

if [ $HAPROXY_READY -lt 1 ]; then
    echo "[ERROR] HAProxy not ready"
    exit 1
fi

echo "[OK] Redis cluster ready: $REDIS_READY/3 pods"
echo "[OK] HAProxy ready with dual backends"
echo ""

# Delete existing benchmark jobs
echo "🧹 Cleaning up previous benchmark jobs..."
kubectl delete job $WRITE_JOB $READ_JOB -n $NAMESPACE --ignore-not-found=true >/dev/null 2>&1
sleep 2

echo ""
echo "=== PHASE 1: Write Benchmark (Data Population) ==="
echo "Target: redis-ha:6379 (Master backend)"
echo "Operation: 100% SET"
echo "Pods: 4 pods x 2 threads x 10 conns = 80 concurrent writes"
echo "Duration: 2 minutes"
echo ""

kubectl apply -f 06a-benchmark-write-job.yaml

echo "📈 Monitoring write benchmark..."
sleep 5

START_TIME=$(date +%s)
while true; do
    WRITE_STATUS=$(kubectl get job $WRITE_JOB -n $NAMESPACE -o json 2>/dev/null || echo "{}")
    
    ACTIVE=$(echo $WRITE_STATUS | jq -r '.status.active // 0')
    SUCCEEDED=$(echo $WRITE_STATUS | jq -r '.status.succeeded // 0')
    FAILED=$(echo $WRITE_STATUS | jq -r '.status.failed // 0')
    
    ELAPSED=$(($(date +%s) - START_TIME))
    
    printf "\r[${ELAPSED}s] Write pods - Running: $ACTIVE | Completed: $SUCCEEDED/4 | Failed: $FAILED"
    
    if [ "$SUCCEEDED" -eq 4 ]; then
        echo ""
        echo "[OK] Write benchmark completed!"
        break
    fi
    
    if [ "$FAILED" -gt 0 ]; then
        echo ""
        echo "[ERROR] Write benchmark failed!"
        exit 1
    fi
    
    sleep 2
done

echo ""
echo "=== PHASE 2: Read Benchmark (Replica Performance) ==="
echo "Target: redis-ha:6380 (Replica backend - 2 replicas)"
echo "Operation: 100% GET"
echo "Pods: 4 pods x 2 threads x 10 conns = 80 concurrent reads"
echo "Duration: 2 minutes"
echo ""

kubectl apply -f 06b-benchmark-read-job.yaml

echo "📈 Monitoring read benchmark..."
sleep 5

START_TIME=$(date +%s)
while true; do
    READ_STATUS=$(kubectl get job $READ_JOB -n $NAMESPACE -o json 2>/dev/null || echo "{}")
    
    ACTIVE=$(echo $READ_STATUS | jq -r '.status.active // 0')
    SUCCEEDED=$(echo $READ_STATUS | jq -r '.status.succeeded // 0')
    FAILED=$(echo $READ_STATUS | jq -r '.status.failed // 0')
    
    ELAPSED=$(($(date +%s) - START_TIME))
    
    printf "\r[${ELAPSED}s] Read pods - Running: $ACTIVE | Completed: $SUCCEEDED/4 | Failed: $FAILED"
    
    if [ "$SUCCEEDED" -eq 4 ]; then
        echo ""
        echo "[OK] Read benchmark completed!"
        break
    fi
    
    if [ "$FAILED" -gt 0 ]; then
        echo ""
        echo "[ERROR] Read benchmark failed!"
        break
    fi
    
    sleep 2
done

echo ""
echo "============================================"
echo "[OK] BENCHMARK COMPLETED!"
echo "============================================"
echo ""
echo "View results:"
echo "  kubectl logs -l tier=write -n $NAMESPACE"
echo "  kubectl logs -l tier=read -n $NAMESPACE"
echo ""
echo "Cleanup:"
echo "  kubectl delete job $WRITE_JOB $READ_JOB -n $NAMESPACE"
echo ""
