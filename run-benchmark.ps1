# Redis Sentinel Dual-Backend Benchmark Script
# Tests write (master) and read (replicas) separately

$NAMESPACE = "redis-sentinel"
$WRITE_JOB = "redis-benchmark-write"
$READ_JOB = "redis-benchmark-read"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Redis Sentinel Dual-Backend Benchmark" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Check if cluster is ready
Write-Host "Checking cluster status..." -ForegroundColor Yellow
$pods = kubectl get pods -n $NAMESPACE --no-headers 2>$null

$redisReady = ($pods | Select-String "redis-" | Select-String "Running").Count
$haproxyReady = ($pods | Select-String "haproxy" | Select-String "2/2.*Running").Count

if ($redisReady -lt 3) {
    Write-Host "ERROR: Redis cluster not ready ($redisReady/3 pods)" -ForegroundColor Red
    exit 1
}

if ($haproxyReady -lt 1) {
    Write-Host "ERROR: HAProxy not ready" -ForegroundColor Red
    exit 1
}

Write-Host "[OK] Redis cluster ready: $redisReady/3 pods" -ForegroundColor Green
Write-Host "[OK] HAProxy ready with dual backends" -ForegroundColor Green
Write-Host ""

# Clean up previous jobs
Write-Host "Cleaning up previous benchmark jobs..." -ForegroundColor Yellow
kubectl delete job $WRITE_JOB $READ_JOB -n $NAMESPACE --ignore-not-found=true | Out-Null
Start-Sleep -Seconds 2

Write-Host ""
Write-Host "=== PHASE 1: Write Benchmark (Data Population) ===" -ForegroundColor Cyan
Write-Host "Target: redis-ha:6379 (Master backend)" -ForegroundColor Gray
Write-Host "Operation: 100% SET" -ForegroundColor Gray
Write-Host "Pods: 4 pods x 2 threads x 10 conns = 80 concurrent writes" -ForegroundColor Gray
Write-Host "Duration: 2 minutes" -ForegroundColor Gray
Write-Host ""

kubectl apply -f 06a-benchmark-write-job.yaml

Write-Host "Monitoring write benchmark..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

$startTime = Get-Date
while ($true) {
    $writeJob = kubectl get job $WRITE_JOB -n $NAMESPACE -o json 2>$null | ConvertFrom-Json
    
    if ($writeJob) {
        $active = if ($writeJob.status.active) { $writeJob.status.active } else { 0 }
        $succeeded = if ($writeJob.status.succeeded) { $writeJob.status.succeeded } else { 0 }
        $failed = if ($writeJob.status.failed) { $writeJob.status.failed } else { 0 }
        
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
        
        Write-Host "`r[${elapsed}s] Write pods - Running: $active | Completed: $succeeded/4 | Failed: $failed" -NoNewline
        
        if ($succeeded -eq 4) {
            Write-Host ""
            Write-Host "[OK] Write benchmark completed!" -ForegroundColor Green
            break
        }
        
        if ($failed -gt 0) {
            Write-Host ""
            Write-Host "[ERROR] Write benchmark failed!" -ForegroundColor Red
            exit 1
        }
    }
    
    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "=== PHASE 2: Read Benchmark (Replica Performance) ===" -ForegroundColor Cyan
Write-Host "Target: redis-ha:6380 (Replica backend - 2 replicas)" -ForegroundColor Gray
Write-Host "Operation: 100% GET" -ForegroundColor Gray
Write-Host "Pods: 4 pods x 2 threads x 10 conns = 80 concurrent reads" -ForegroundColor Gray
Write-Host "Duration: 2 minutes" -ForegroundColor Gray
Write-Host ""

kubectl apply -f 06b-benchmark-read-job.yaml

Write-Host "Monitoring read benchmark..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

$startTime = Get-Date
while ($true) {
    $readJob = kubectl get job $READ_JOB -n $NAMESPACE -o json 2>$null | ConvertFrom-Json
    
    if ($readJob) {
        $active = if ($readJob.status.active) { $readJob.status.active } else { 0 }
        $succeeded = if ($readJob.status.succeeded) { $readJob.status.succeeded } else { 0 }
        $failed = if ($readJob.status.failed) { $readJob.status.failed } else { 0 }
        
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
        
        Write-Host "`r[${elapsed}s] Read pods - Running: $active | Completed: $succeeded/4 | Failed: $failed" -NoNewline
        
        if ($succeeded -eq 4) {
            Write-Host ""
            Write-Host "[OK] Read benchmark completed!" -ForegroundColor Green
            break
        }
        
        if ($failed -gt 0) {
            Write-Host ""
            Write-Host "[ERROR] Read benchmark failed!" -ForegroundColor Red
            break
        }
    }
    
    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "BENCHMARK COMPLETED!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "View results:" -ForegroundColor Cyan
Write-Host "  kubectl logs -l tier=write -n $NAMESPACE" -ForegroundColor White
Write-Host "  kubectl logs -l tier=read -n $NAMESPACE" -ForegroundColor White
Write-Host ""
Write-Host "Cleanup:" -ForegroundColor Cyan
Write-Host "  kubectl delete job $WRITE_JOB $READ_JOB -n $NAMESPACE" -ForegroundColor White
Write-Host ""
