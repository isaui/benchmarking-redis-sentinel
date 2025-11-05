# Redis Sentinel di Kubernetes

Setup Redis dengan high availability menggunakan Sentinel untuk automatic failover.

## Arsitektur

```
┌──────────────────────────────────────────────────┐
│         KUBERNETES CLUSTER                       │
│                                                  │
│  ┌────────────────────────────────────────────┐ │
│  │   CLIENTS (Apps / Benchmark)               │ │
│  └────────────────┬───────────────────────────┘ │
│                   │ Connect via redis-ha       │
│                   ↓                             │
│  ┌────────────────────────────────────────────┐ │
│  │   HAPROXY (Auto-routing)                   │ │
│  │   - Query Sentinel for master              │ │
│  │   - Route to current master                │ │
│  │   - Handle failover automatically          │ │
│  │   Service: redis-ha:6379                   │ │
│  └──────────────┬─────────────────────────────┘ │
│                 │                               │
│  ┌──────────────┴──────────────────────┐       │
│  │   SENTINEL PODS (Deployment)        │       │
│  │   ├─ sentinel-xxx-1 (26379)         │       │
│  │   ├─ sentinel-xxx-2 (26379)         │       │
│  │   └─ sentinel-xxx-3 (26379)         │       │
│  │   Quorum: 2/3 untuk failover        │       │
│  └────────────────────────┬────────────┘       │
│                            │ Monitor            │
│                            ↓                    │
│  ┌──────────────────────────────────────────┐  │
│  │   REDIS PODS (StatefulSet)               │  │
│  │   ├─ redis-0 (MASTER) ←─ Writes          │  │
│  │   ├─ redis-1 (REPLICA)                   │  │
│  │   └─ redis-2 (REPLICA)                   │  │
│  │   Port: 6379                             │  │
│  └──────────────────────────────────────────┘  │
└──────────────────────────────────────────────────┘
```

## File Structure

File YAML diberi prefix angka untuk menunjukkan deployment order:

```
00-namespace.yaml           # Namespace (deploy first)
01-configmap-redis.yaml     # Redis configuration
02-configmap-sentinel.yaml  # Sentinel configuration
03-service.yaml             # Redis & Sentinel services
04-statefulset-redis.yaml   # Redis pods
05-deployment-sentinel.yaml # Sentinel pods
06-benchmark-job.yaml       # Performance testing (optional)
07-haproxy-configmap.yaml   # HAProxy config & sentinel-watcher
08-haproxy-deployment.yaml  # HAProxy with Sentinel integration
09-haproxy-service.yaml     # HAProxy service (redis-ha)

deploy.sh / deploy.ps1      # Deployment automation scripts
run-benchmark.sh / .ps1     # Benchmark testing scripts
```

Deployment script akan otomatis deploy sesuai urutan ini.

## Komponen

### Redis StatefulSet
- **1 Master** (redis-0): Read + Write
- **2 Replica** (redis-1, redis-2): Read only
- Persistent storage: 1Gi per pod
- Auto-replication dari master

### Sentinel Deployment
- **3 Sentinel pods**: Monitoring & failover
- **Quorum: 2**: Minimal 2 sentinel setuju untuk failover
- **Failover timeout**: 3 menit
- **Detection timeout**: 5 detik

### HAProxy (Smart Router)
- **Sentinel-aware proxy**: Auto-discovers current master
- **Dynamic routing**: Routes traffic to active master only
- **Failover handling**: Automatic reconnection during failover
- **Service endpoint**: `redis-ha:6379` (single endpoint for clients)
- **Monitoring**: Stats page on port 8404

## 🚀 Deployment

### 1. Deploy ke Kubernetes

```bash
# Deploy semua resources (ordered by prefix)
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-configmap-redis.yaml
kubectl apply -f 02-configmap-sentinel.yaml
kubectl apply -f 03-service.yaml
kubectl apply -f 04-statefulset-redis.yaml
kubectl apply -f 05-deployment-sentinel.yaml

# Atau gunakan deployment script
./deploy.sh apply          # Linux/Mac
.\deploy.ps1 -Action apply # Windows PowerShell
```

### 2. Verifikasi Deployment

```bash
# Cek semua pods
kubectl get pods -n redis-sentinel

# Expected output:
# NAME         READY   STATUS    RESTARTS   AGE
# redis-0      1/1     Running   0          2m
# redis-1      1/1     Running   0          1m
# redis-2      1/1     Running   0          1m
# sentinel-xxx 1/1     Running   0          30s
# sentinel-yyy 1/1     Running   0          30s
# sentinel-zzz 1/1     Running   0          30s
```

### 3. Cek Services

```bash
kubectl get svc -n redis-sentinel

# Expected output:
# NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)
# redis              ClusterIP   10.x.x.x        <none>        6379/TCP
# redis-headless     ClusterIP   None            <none>        6379/TCP
# sentinel           ClusterIP   10.x.x.x        <none>        26379/TCP
# sentinel-headless  ClusterIP   None            <none>        26379/TCP
```

## Testing

### 1. Cek Redis Replication

```bash
# Connect ke master
kubectl exec -it redis-0 -n redis-sentinel -- redis-cli

# Cek role
127.0.0.1:6379> ROLE
# Output: master

# Cek replica
127.0.0.1:6379> INFO replication
```

```bash
# Connect ke replica
kubectl exec -it redis-1 -n redis-sentinel -- redis-cli

# Cek role
127.0.0.1:6379> ROLE
# Output: slave
```

### 2. Cek Sentinel Status

```bash
# Connect ke sentinel
kubectl exec -it deployment/sentinel -n redis-sentinel -- redis-cli -p 26379

# Cek master info
127.0.0.1:26379> SENTINEL master mymaster

# Cek sentinel count
127.0.0.1:26379> SENTINEL sentinels mymaster

# Cek replica count
127.0.0.1:26379> SENTINEL replicas mymaster
```

### 3. Test Write/Read

```bash
# Write ke master
kubectl exec -it redis-0 -n redis-sentinel -- redis-cli SET test "Hello Sentinel"

# Read dari replica
kubectl exec -it redis-1 -n redis-sentinel -- redis-cli GET test
# Output: "Hello Sentinel"
```

## Test Failover (Chaos Engineering)

### Manual Failover Test

```bash
# 1. Cek master saat ini
kubectl exec -it deployment/sentinel -n redis-sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# Output: redis-0 IP

# 2. Kill master pod
kubectl delete pod redis-0 -n redis-sentinel

# 3. Watch failover (5-10 detik)
kubectl exec -it deployment/sentinel -n redis-sentinel -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# Output: redis-1 atau redis-2 IP (NEW MASTER!)

# 4. Cek logs sentinel untuk failover event
kubectl logs -f deployment/sentinel -n redis-sentinel | grep failover
```

### Expected Failover Timeline

```
T+0s:   redis-0 deleted (master down)
T+5s:   Sentinel detect master down
T+8s:   Sentinel voting (quorum reached)
T+10s:  Sentinel promote redis-1 as new master
T+12s:  redis-2 reconfigured to follow new master
T+15s:  Old redis-0 back as replica (if restarted)
```

## Monitoring

### Watch Pods

```bash
# Terminal 1: Watch pods
kubectl get pods -n redis-sentinel -w

# Terminal 2: Watch events
kubectl get events -n redis-sentinel -w

# Terminal 3: Sentinel logs
kubectl logs -f deployment/sentinel -n redis-sentinel
```

### Check Persistent Volumes

```bash
# Cek PVC untuk Redis data
kubectl get pvc -n redis-sentinel

# Expected: 3 PVCs (redis-data-redis-0/1/2)
```

## Troubleshooting

### Problem: Sentinel tidak detect master

```bash
# Cek sentinel config
kubectl exec -it deployment/sentinel -n redis-sentinel -- cat /data/sentinel.conf

# Cek connectivity ke master
kubectl exec -it deployment/sentinel -n redis-sentinel -- \
  redis-cli -h redis-0.redis-headless.redis-sentinel.svc.cluster.local -p 6379 PING
```

### Problem: Replication lag

```bash
# Cek offset di master
kubectl exec -it redis-0 -n redis-sentinel -- \
  redis-cli INFO replication | grep master_repl_offset

# Cek offset di replica
kubectl exec -it redis-1 -n redis-sentinel -- \
  redis-cli INFO replication | grep slave_repl_offset
```

### Problem: Split brain

```bash
# Cek semua pod roles
for i in 0 1 2; do
  echo "=== redis-$i ==="
  kubectl exec -it redis-$i -n redis-sentinel -- redis-cli ROLE
done

# Seharusnya hanya 1 master!
```

## Cleanup

```bash
# Delete semua resources
kubectl delete namespace redis-sentinel

# Atau per-file (reverse order)
kubectl delete -f 05-deployment-sentinel.yaml
kubectl delete -f 04-statefulset-redis.yaml
kubectl delete -f 03-service.yaml
kubectl delete -f 02-configmap-sentinel.yaml
kubectl delete -f 01-configmap-redis.yaml
kubectl delete -f 00-namespace.yaml

# Atau gunakan deployment script
./deploy.sh delete          # Linux/Mac
.\deploy.ps1 -Action delete # Windows PowerShell
```

## Configuration Tuning

### Sentinel Timeouts

Edit `02-configmap-sentinel.yaml`:

```yaml
# Faster failover (risky for network hiccup)
sentinel down-after-milliseconds mymaster 3000  # 3s instead of 5s

# Slower failover (more stable)
sentinel down-after-milliseconds mymaster 10000  # 10s
```

### Redis Memory

Edit `04-statefulset-redis.yaml`:

```yaml
# Increase memory per pod
maxmemory 512mb  # instead of 256mb
```

Apply changes:
```bash
kubectl apply -f 02-configmap-sentinel.yaml
kubectl rollout restart deployment/sentinel -n redis-sentinel
```

## Performance Testing dengan Memtier Benchmark

### Benchmark Configuration

Test setup menggunakan `memtier_benchmark` dengan spesifikasi:

```
- 4 Kubernetes Job pods (parallel execution)
- 2 threads per pod
- 10 connections per thread
- Total: 80 concurrent connections
- Test duration: 2 minutes (120 seconds)
- Operation ratio: 50% SET, 50% GET (1:1)
- Data size: 256 bytes per key
- Key pattern: Sequential
```

### Running Benchmark

```bash
# Pastikan Redis Sentinel sudah running
kubectl get pods -n redis-sentinel

# Run benchmark dengan script
./run-benchmark.sh          # Linux/Mac
.\run-benchmark.ps1         # Windows PowerShell

# Atau manual
kubectl apply -f 06-benchmark-job.yaml

# Monitor progress
kubectl get pods -n redis-sentinel -l app=redis-benchmark -w

# Lihat logs semua pods
kubectl logs -l app=redis-benchmark -n redis-sentinel --tail=100
```

### Expected Results

Benchmark akan menghasilkan metrics:

- **Throughput**: Total ops/sec dari semua pods
- **Latency**: p50, p90, p95, p99, p99.9 percentiles
- **Hits/Misses**: GET hit rate
- **Bandwidth**: KB/sec untuk SET dan GET operations

### Cleanup Benchmark

```bash
# Delete benchmark job
kubectl delete job redis-benchmark -n redis-sentinel

# Pods akan otomatis di-cleanup setelah job selesai
```

### Benchmark Results Analysis

```bash
# Aggregate results dari semua pods
for pod in $(kubectl get pods -n redis-sentinel -l app=redis-benchmark -o name); do
  echo "=== $pod ==="
  kubectl logs $pod -n redis-sentinel | grep "Totals"
done

# Export results ke file
kubectl logs -l app=redis-benchmark -n redis-sentinel > benchmark-results.txt
```

## Next Steps

Setelah Redis Sentinel setup berhasil:
1. ✅ **Testing normal operations**
2. ✅ **Testing failover scenario**
3. ✅ **Setup memtier_benchmark** (performance testing)
4. 🔜 **Benchmark under failover** (chaos testing)
5. 🔜 **Prometheus monitoring**

---

**Status**: Ready for production testing ✅
