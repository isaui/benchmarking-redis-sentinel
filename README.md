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
06a-benchmark-write-job.yaml # Write benchmark (master)
06b-benchmark-read-job.yaml  # Read benchmark (replicas)
07-haproxy-configmap.yaml   # HAProxy config & sentinel-watcher
08-haproxy-deployment.yaml  # HAProxy with Sentinel integration
09-haproxy-service.yaml     # HAProxy service (redis-ha)

deploy.sh / deploy.ps1      # Deployment automation scripts
run-benchmark.sh / .ps1     # Dual-backend benchmark scripts
BENCHMARK.md                # Detailed benchmark guide
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

**Recommended: Gunakan deployment script (includes HAProxy)**

```bash
# Linux/Mac
./deploy.sh apply

# Windows PowerShell
.\deploy.ps1 -Action apply
```

**Manual deployment:**

```bash
# Deploy semua resources (ordered by prefix)
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-configmap-redis.yaml
kubectl apply -f 02-configmap-sentinel.yaml
kubectl apply -f 03-service.yaml
kubectl apply -f 04-statefulset-redis.yaml
kubectl apply -f 05-deployment-sentinel.yaml

# Deploy HAProxy (Sentinel-aware router)
kubectl apply -f 07-haproxy-configmap.yaml
kubectl apply -f 08-haproxy-deployment.yaml
kubectl apply -f 09-haproxy-service.yaml
```

### 2. Verifikasi Deployment

```bash
# Cek semua pods
kubectl get pods -n redis-sentinel

# Expected output:
# NAME              READY   STATUS    RESTARTS   AGE
# haproxy-xxx       2/2     Running   0          1m
# redis-0           1/1     Running   0          2m
# redis-1           1/1     Running   0          2m
# redis-2           1/1     Running   0          2m
# sentinel-xxx      1/1     Running   0          2m
# sentinel-yyy      1/1     Running   0          2m
# sentinel-zzz      1/1     Running   0          2m
```

### 3. Cek Services

```bash
kubectl get svc -n redis-sentinel

# Expected output:
# NAME               TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)
# haproxy-stats      ClusterIP   10.x.x.x        <none>        8404/TCP
# redis              ClusterIP   10.x.x.x        <none>        6379/TCP
# redis-ha           ClusterIP   10.x.x.x        <none>        6379/TCP,8404/TCP  ← USE THIS!
# redis-headless     ClusterIP   None            <none>        6379/TCP
# sentinel           ClusterIP   10.x.x.x        <none>        26379/TCP
# sentinel-headless  ClusterIP   None            <none>        26379/TCP
```

**⚠️ Important:** Aplikasi/clients harus connect ke `redis-ha:6379`, BUKAN `redis` service!

## Testing

### 1. Test Connection via HAProxy

```bash
# Test PING (recommended way)
kubectl run redis-test --image=redis:7.2-alpine -n redis-sentinel --rm -it --restart=Never -- redis-cli -h redis-ha PING
# Expected: PONG

# Test SET
kubectl run redis-test --image=redis:7.2-alpine -n redis-sentinel --rm -it --restart=Never -- redis-cli -h redis-ha SET mykey "Hello Sentinel"
# Expected: OK

# Test GET
kubectl run redis-test --image=redis:7.2-alpine -n redis-sentinel --rm -it --restart=Never -- redis-cli -h redis-ha GET mykey
# Expected: "Hello Sentinel"
```

### 2. Cek Redis Replication

```bash
# Connect ke master (direct)
kubectl exec -it redis-0 -n redis-sentinel -- redis-cli

# Cek role
127.0.0.1:6379> ROLE
# Output: master

# Cek replica
127.0.0.1:6379> INFO replication

# Connect ke replica
kubectl exec -it redis-1 -n redis-sentinel -- redis-cli

# Cek role
127.0.0.1:6379> ROLE
# Output: slave
```

### 3. Cek Sentinel Status

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

### 4. HAProxy Monitoring

```bash
# Port forward HAProxy stats page
kubectl port-forward svc/haproxy-stats 8404:8404 -n redis-sentinel

# Open browser: http://localhost:8404
# You'll see:
# - Current backend server (master IP)
# - Connection statistics
# - Health check status
```

### 5. Test Write/Read via HAProxy

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

## 📊 Performance Testing dengan Memtier Benchmark

Setup benchmark menggunakan **HAProxy Dual-Backend** untuk test write/read performance dan Sentinel failover.

### Architecture

```
Write Benchmark (4 pods)
    ↓
redis-ha:6379 (HAProxy) → master_backend → Redis Master
                              ↓
                        Sentinel (discovery)

Read Benchmark (4 pods)
    ↓  
redis-ha:6380 (HAProxy) → replica_backend → 2 Replicas (round-robin)
                              ↓
                        Sentinel (discovery)
```

### Benchmark Configuration

**Write Benchmark** (`06a-benchmark-write-job.yaml`):
```
- Target: redis-ha:6379 (master_backend)
- Operation: 100% SET (data population)
- Pods: 4 pods × 2 threads × 10 connections = 80 concurrent writes
- Duration: 2 minutes
- Data size: 256 bytes per key
```

**Read Benchmark** (`06b-benchmark-read-job.yaml`):
```
- Target: redis-ha:6380 (replica_backend - 2 replicas)
- Operation: 100% GET (read from replicas)
- Pods: 4 pods × 2 threads × 10 connections = 80 concurrent reads
- Duration: 2 minutes
- Load balancing: Round-robin across 2 replicas
```

### Running Benchmark

**Option 1: Automated Script (Recommended)**

```bash
# Linux/Mac
./run-benchmark.sh

# Windows PowerShell
.\run-benchmark.ps1
```

Script akan otomatis:
- Check Redis + HAProxy readiness
- Clean up old benchmark jobs
- **Phase 1**: Run write benchmark (populate data to master)
- **Phase 2**: Run read benchmark (read from 2 replicas)
- Monitor progress real-time
- Show commands to view results

**Output:**
```
============================================
BENCHMARK COMPLETED!
============================================

View results:
  kubectl logs -l tier=write -n redis-sentinel
  kubectl logs -l tier=read -n redis-sentinel

Cleanup:
  kubectl delete job redis-benchmark-write redis-benchmark-read -n redis-sentinel
```

### Expected Results

**Write Performance** (to Master):
- ~7,000 ops/sec aggregate (4 pods)
- ~1,750 ops/sec per pod
- Latency p50: ~1.7ms, p99: ~90ms

**Read Performance** (from 2 Replicas):
- ~7,000 ops/sec aggregate (4 pods)
- Load balanced across 2 replicas
- Latency p50: ~1.7ms, p99: ~90ms

### Cleanup

```bash
kubectl delete job redis-benchmark-write redis-benchmark-read -n redis-sentinel
```

### Detailed Guide

**📖 Full benchmark documentation:** [BENCHMARK.md](BENCHMARK.md)

Covers:
- Detailed architecture
- Monitoring during benchmark
- Failover testing under load
- Results analysis
- Troubleshooting

## Summary

**What You Get:**
- ✅ Redis Sentinel (3 replicas, 3 sentinels) with automatic failover
- ✅ HAProxy Dual-Backend (separate write/read paths)
- ✅ Sentinel-aware routing (auto-discovers master & replicas)
- ✅ Performance testing with memtier_benchmark
- ✅ Production-ready setup on Kubernetes

**Key Features:**
- **High Availability**: Automatic failover in ~10 seconds
- **Read Scaling**: Load-balanced reads across 2 replicas
- **Single Endpoint**: `redis-ha:6379` (writes), `redis-ha:6380` (reads)
- **Zero Downtime**: Seamless failover handling
- **Performance**: ~7,000 ops/sec on Minikube

**Quick Commands:**
```bash
# Deploy everything
./deploy.sh apply

# Run benchmark
./run-benchmark.sh

# Monitor
kubectl get pods -n redis-sentinel
kubectl port-forward svc/haproxy-stats 8404:8404 -n redis-sentinel

# Cleanup
./deploy.sh delete
```

**Documentation:**
- **[BENCHMARK.md](BENCHMARK.md)**: Full benchmark guide & results
- **This README**: Setup & architecture overview

---

**Status**: Ready for production testing ✅
