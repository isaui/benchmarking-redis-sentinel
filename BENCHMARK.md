# Redis Sentinel Benchmark Guide

Performance testing guide untuk Redis Sentinel dengan HAProxy dan memtier_benchmark.

## Architecture

Benchmark menggunakan **HAProxy** sebagai smart router yang:
- Auto-discovers current master via Sentinel
- Routes all traffic to active master
- Handles failover automatically
- Provides single endpoint untuk clients

```
Benchmark Pods (4x) → redis-ha:6379 (HAProxy) → Current Master
                           ↓
                      Sentinel (discovery)
```

## Quick Start

```bash
# 1. Deploy Redis Sentinel + HAProxy
./deploy.sh apply          # Linux/Mac
.\deploy.ps1 -Action apply # Windows

# 2. Wait for all pods ready (~1 minute)
kubectl get pods -n redis-sentinel
# Expect: redis-0/1/2, sentinel-xxx (3x), haproxy-xxx (2/2 ready)

# 3. Run benchmark
./run-benchmark.sh          # Linux/Mac
.\run-benchmark.ps1         # Windows

# 4. View results
kubectl logs -l app=redis-benchmark -n redis-sentinel --tail=50
```

## Benchmark Specifications

### Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| **Target** | `redis-ha:6379` | HAProxy endpoint |
| **Pods** | 4 | Parallel execution |
| **Threads per pod** | 2 | CPU threads |
| **Connections per thread** | 10 | TCP connections |
| **Total connections** | 80 | 4 pods × 2 threads × 10 conns |
| **Test duration** | 120s | 2 minutes |
| **Operation ratio** | 1:1 | 50% SET, 50% GET |
| **Data size** | 256 bytes | Per key-value pair |
| **Pipeline** | 1 | Requests per pipeline |
| **Key pattern** | Random (S:S) | Distinct seed per client |

### Load Distribution

```
Connection Flow:
  80 clients → redis-ha (HAProxy) → Current Master (auto-discovered)

Operation types:
  - SET operations: ~50% (writes to master via HAProxy)
  - GET operations: ~50% (reads from master via HAProxy)
  
Data pattern:
  - Random keys with sequential pattern (S:S)
  - 256 bytes per key-value
  - Distinct seed per client (no key collision)
  
Failover handling:
  - HAProxy detects new master from Sentinel (~5s)
  - Automatic reconnection to new master
  - Minimal benchmark interruption
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

### Monitor During Benchmark

**Terminal 1 - HAProxy Stats:**
```bash
# Port forward HAProxy stats page
kubectl port-forward svc/haproxy-stats 8404:8404 -n redis-sentinel

# Open browser: http://localhost:8404
# Monitor:
# - Current backend (master IP)
# - Active connections (should show ~80)
# - Request rate
```

**Terminal 2 - Redis Stats:**
```bash
# Watch master operations
watch -n 1 'kubectl exec redis-0 -n redis-sentinel -- redis-cli INFO stats | grep -E "total_commands|instantaneous"'
```

**Terminal 3 - Sentinel Status:**
```bash
# Monitor current master
watch -n 2 'kubectl exec deployment/sentinel -n redis-sentinel -- redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster'
```

**Terminal 4 - Pod Resources:**
```bash
kubectl top pods -n redis-sentinel
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

**Per Pod (actual result via HAProxy):**
```
Type         Ops/sec     Hits/sec   Misses/sec    Avg. Latency     p50      p99      p99.9    KB/sec
-------------------------------------------------------------------------------------------------------
Sets          900.81          ---          ---        11.25412     1.687    89.599    94.719   264.60
Gets          900.75       900.75         0.00        11.12670     1.687    89.599    94.719   260.19
Totals       1801.55       900.75         0.00        11.19041     1.687    89.599    94.719   524.79
```

**Aggregate (4 pods combined):**
```
Total Throughput: ~7,200 ops/sec
  - SETs: ~3,600 ops/sec
  - GETs: ~3,600 ops/sec
  - Bandwidth: ~2 MB/sec

Latency (all pods):
  - p50 (Median): 1.68-1.72 ms  ← Excellent!
  - p90: 82-84 ms
  - p95: 87 ms
  - p99: 89-90 ms
  - p99.9: 94-95 ms
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
# Test HAProxy connectivity
kubectl run -it --rm debug --image=redis:7.2-alpine -n redis-sentinel -- \
  redis-cli -h redis-ha PING

# Should return: PONG

# If fails, check components:

# 1. Check HAProxy status
kubectl get pods -l app=haproxy -n redis-sentinel
kubectl logs -l app=haproxy -n redis-sentinel -c haproxy --tail=20

# 2. Check Sentinel can discover master
kubectl exec deployment/sentinel -n redis-sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# 3. Check HAProxy service
kubectl get svc redis-ha -n redis-sentinel

# 4. Check DNS resolution
kubectl run -it --rm debug --image=busybox -n redis-sentinel -- \
  nslookup redis-ha.redis-sentinel.svc.cluster.local
```

## Advanced: Benchmark During Failover

Test automatic failover with HAProxy under load:

```bash
# Terminal 1: Start benchmark
./run-benchmark.sh

# Terminal 2: Monitor HAProxy sentinel-watcher
kubectl logs -f -l app=haproxy -n redis-sentinel -c sentinel-watcher

# Terminal 3: Monitor current master
watch -n 1 'kubectl exec deployment/sentinel -n redis-sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster'

# Terminal 4: After 30s, kill current master
kubectl get pods -n redis-sentinel -l app=redis
kubectl delete pod redis-1 -n redis-sentinel  # or whichever is master

# Observe failover timeline:
# T+0s:  Master pod deleted
# T+5s:  Sentinel detects failure
# T+10s: Sentinel promotes new master
# T+12s: HAProxy watcher detects change
# T+13s: HAProxy updates backend to new master
# T+14s: Benchmark reconnects, continues

# Expected impact:
# - Total downtime: ~10-15 seconds
# - Connection errors during failover: Yes (brief)
# - Data loss: None
# - Benchmark completes successfully
```

### Failover Test Results

After successful failover:

```bash
# Check new master
kubectl exec deployment/sentinel -n redis-sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# Check HAProxy backend
kubectl exec -l app=haproxy -n redis-sentinel -c haproxy -- \
  sh -c "echo 'show servers state' | socat - /var/run/haproxy.sock | grep redis"

# Both should show same new master IP
```

## Performance Expectations

### Minikube (Local Development)

Actual results on Minikube via HAProxy:

```
Configuration: 4 pods, 2 threads, 10 connections
Total connections: 80
Connection: redis-ha (HAProxy) → Master

Throughput (Aggregate):
  - SETs: ~3,500-3,600 ops/sec
  - GETs: ~3,500-3,600 ops/sec
  - Total: ~7,000-7,200 ops/sec

Latency:
  - p50 (Median): 1.68-1.72 ms  ✓ Excellent
  - p90: 82-84 ms
  - p95: 87 ms
  - p99: 89-90 ms
  - p99.9: 94-95 ms

Bandwidth:
  - ~2 MB/sec total
  - ~500 KB/sec per pod
```

### Production Cluster (Estimated)

On real Kubernetes cluster with dedicated resources:

```
Expected throughput: 50,000 - 100,000+ ops/sec
Expected p99 latency: < 5ms
Bandwidth: 10-20 MB/sec

Factors:
- Better network (no Docker Desktop overhead)
- More CPU/memory resources
- SSD storage for Redis
- Multiple worker nodes
```

**Note**: Results vary based on hardware, Minikube configuration, and system load.

---

**Tips:**
- Run benchmark multiple times for consistent results
- Warm up Redis with data before measuring peak performance
- Monitor system resources during benchmark
- Compare results before/after configuration changes
