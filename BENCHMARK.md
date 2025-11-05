# Redis Sentinel Benchmark Guide

Quick reference untuk performance testing Redis Sentinel dengan memtier_benchmark.

## Quick Start

```bash
# 1. Deploy Redis Sentinel
./deploy.sh apply

# 2. Wait for pods ready (tunggu ~30 detik)
kubectl get pods -n redis-sentinel

# 3. Run benchmark
./run-benchmark.sh          # Linux/Mac
.\run-benchmark.ps1         # Windows

# 4. View results
kubectl logs -l app=redis-benchmark -n redis-sentinel
```

## Benchmark Specifications

### Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| **Pods** | 4 | Parallel execution |
| **Threads per pod** | 2 | CPU threads |
| **Connections per thread** | 10 | TCP connections |
| **Total connections** | 80 | 4 pods × 2 threads × 10 conns |
| **Test duration** | 120s | 2 minutes |
| **Operation ratio** | 1:1 | 50% SET, 50% GET |
| **Data size** | 256 bytes | Per key-value pair |
| **Pipeline** | 1 | Requests per pipeline |

### Expected Load

```
Total concurrent operations: 80 connections
Operation types:
  - SET operations: ~50% (write to master)
  - GET operations: ~50% (read from replicas)
  
Data pattern:
  - Sequential keys (S:S pattern)
  - Random data per key
  - Distinct seed per client
```

## Monitoring

### Watch Benchmark Progress

```bash
# Monitor job status
kubectl get job redis-benchmark -n redis-sentinel -w

# Watch pods
kubectl get pods -l app=redis-benchmark -n redis-sentinel -w

# Follow logs from all pods
kubectl logs -f -l app=redis-benchmark -n redis-sentinel --max-log-requests=10
```

### Monitor Redis During Benchmark

Terminal 1 - Redis Stats:
```bash
watch -n 1 'kubectl exec redis-0 -n redis-sentinel -- redis-cli INFO stats | grep -E "total_commands|instantaneous"'
```

Terminal 2 - Sentinel Status:
```bash
watch -n 2 'kubectl exec deployment/sentinel -n redis-sentinel -- redis-cli -p 26379 SENTINEL master mymaster | grep -E "name|flags|num-slaves"'
```

Terminal 3 - Pod Resources:
```bash
kubectl top pods -n redis-sentinel -l app=redis
```

## Results Analysis

### View Results

```bash
# Quick summary
kubectl logs -l app=redis-benchmark -n redis-sentinel | grep -A5 "Totals"

# Detailed per-pod results
for pod in $(kubectl get pods -l app=redis-benchmark -n redis-sentinel -o name); do
  echo "========================================="
  echo "$pod"
  echo "========================================="
  kubectl logs $pod -n redis-sentinel | grep -E "Type|Ops/sec|Latency|Bandwidth"
  echo ""
done

# Export to file
kubectl logs -l app=redis-benchmark -n redis-sentinel > results-$(date +%Y%m%d-%H%M%S).txt
```

### Key Metrics

**Throughput Metrics:**
- `Ops/sec`: Operations per second
- `Hits/sec`: Successful GET operations
- `Misses/sec`: Failed GET operations (key not found)

**Latency Metrics (milliseconds):**
- `p50`: Median latency
- `p90`: 90th percentile
- `p95`: 95th percentile
- `p99`: 99th percentile
- `p99.9`: 99.9th percentile

**Bandwidth:**
- `KB/sec`: Network throughput

### Example Output

```
Type         Ops/sec     Hits/sec   Misses/sec    Avg. Latency     p50      p99    p99.9    KB/sec
------------------------------------------------------------------------
Sets        15234.56          ---          ---         0.32312     0.30     0.75    1.20     1234.5
Gets        15187.23     15187.23         0.00         0.31892     0.29     0.72    1.15     5678.9
Totals      30421.79     15187.23         0.00         0.32102     0.30     0.74    1.18     6913.4
```

## Benchmark Scenarios

### 1. Normal Load Test (Default)

```bash
# Current configuration: 80 connections, 2 minutes
./run-benchmark.sh
```

### 2. High Load Test

Edit `06-benchmark-job.yaml`:
```yaml
parallelism: 8              # 8 pods instead of 4
completions: 8
--clients=20                # 20 connections per thread
--threads=4                 # 4 threads per pod
# Total: 8 × 4 × 20 = 640 connections
```

### 3. Write-Heavy Test

Edit `06-benchmark-job.yaml`:
```yaml
--ratio=3:1                 # 75% SET, 25% GET
```

### 4. Read-Heavy Test

Edit `06-benchmark-job.yaml`:
```yaml
--ratio=1:3                 # 25% SET, 75% GET
```

### 5. Large Data Test

Edit `06-benchmark-job.yaml`:
```yaml
--data-size=1024            # 1KB per key instead of 256 bytes
```

## Cleanup

```bash
# Delete benchmark job
kubectl delete job redis-benchmark -n redis-sentinel

# Verify cleanup
kubectl get pods -l app=redis-benchmark -n redis-sentinel
# Should return: No resources found
```

## Troubleshooting

### Benchmark Pods Failing

```bash
# Check pod status
kubectl describe pod -l app=redis-benchmark -n redis-sentinel

# Check logs
kubectl logs -l app=redis-benchmark -n redis-sentinel

# Common issues:
# 1. Redis not ready: Wait for Redis pods to be Running
# 2. Connection timeout: Check service DNS resolution
# 3. OOM: Increase pod memory limits
```

### Low Throughput

```bash
# Check Redis resource usage
kubectl top pods -n redis-sentinel -l app=redis

# Check if replicas are lagging
kubectl exec redis-0 -n redis-sentinel -- redis-cli INFO replication | grep lag

# Possible causes:
# 1. CPU throttling: Increase resource requests
# 2. Network bottleneck: Check node network capacity
# 3. Disk I/O: Check PVC performance (especially on Minikube)
```

### Connection Errors

```bash
# Test Redis connectivity from benchmark pod
kubectl run -it --rm debug --image=redis:7.2-alpine -n redis-sentinel -- \
  redis-cli -h redis.redis-sentinel.svc.cluster.local PING

# Should return: PONG

# If fails:
# 1. Check service exists: kubectl get svc -n redis-sentinel
# 2. Check DNS: kubectl run -it --rm debug --image=busybox -n redis-sentinel -- \
#               nslookup redis.redis-sentinel.svc.cluster.local
```

## Advanced: Benchmark During Failover

Test Redis Sentinel automatic failover under load:

```bash
# Terminal 1: Start benchmark
./run-benchmark.sh

# Terminal 2: Monitor sentinel
watch -n 1 'kubectl exec deployment/sentinel -n redis-sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster'

# Terminal 3: After 30s, kill master
kubectl delete pod redis-0 -n redis-sentinel

# Observe:
# - Sentinel detects failure (~5s)
# - New master elected (~10s)
# - Benchmark continues with minimal impact
```

## Performance Expectations (Minikube)

Typical results on Minikube (local machine):

```
Configuration: 4 pods, 2 threads, 10 connections
Total connections: 80

Expected throughput:
  - Sets: 10,000 - 20,000 ops/sec
  - Gets: 10,000 - 20,000 ops/sec
  - Total: 20,000 - 40,000 ops/sec

Expected latency (p99):
  - Normal: < 2ms
  - Under failover: 5-10ms spike
```

**Note**: Production clusters on real hardware will achieve 10-100x higher throughput.

---

**Tips:**
- Run benchmark multiple times for consistent results
- Warm up Redis with data before measuring peak performance
- Monitor system resources during benchmark
- Compare results before/after configuration changes
