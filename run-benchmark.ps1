# Redis Sentinel Benchmark Script
# Usage: .\run-benchmark.ps1

$NAMESPACE = "redis-sentinel"
$JOB_NAME = "redis-benchmark"

Write-Host "================================" -ForegroundColor Cyan
Write-Host "Redis Sentinel Benchmark Test" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

# Check if Redis is ready
Write-Host "Checking Redis cluster status..." -ForegroundColor Yellow
$redisStatus = kubectl get pods -n $NAMESPACE -l app=redis -o json | ConvertFrom-Json
$readyPods = ($redisStatus.items | Where-Object { $_.status.phase -eq "Running" }).Count

if ($readyPods -lt 3) {
    Write-Host "ERROR: Redis cluster not ready ($readyPods/3 pods running)" -ForegroundColor Red
    exit 1
}

Write-Host "Redis cluster ready: $readyPods/3 pods running" -ForegroundColor Green
Write-Host ""

# Delete existing benchmark job if any
Write-Host "Cleaning up previous benchmark jobs..." -ForegroundColor Yellow
kubectl delete job $JOB_NAME -n $NAMESPACE --ignore-not-found=true | Out-Null
Start-Sleep -Seconds 2

# Deploy benchmark job
Write-Host "Starting benchmark job (4 pods, 2 threads, 10 connections each)..." -ForegroundColor Yellow
kubectl apply -f 06-benchmark-job.yaml

Write-Host ""
Write-Host "Waiting for benchmark pods to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# Watch job progress
Write-Host ""
Write-Host "Benchmark Configuration:" -ForegroundColor Cyan
Write-Host "  - Pods: 4 (parallel)" -ForegroundColor Gray
Write-Host "  - Threads per pod: 2" -ForegroundColor Gray
Write-Host "  - Connections per thread: 10" -ForegroundColor Gray
Write-Host "  - Total connections: 80 (4 pods x 2 threads x 10 conns)" -ForegroundColor Gray
Write-Host "  - Test duration: 2 minutes (120 seconds)" -ForegroundColor Gray
Write-Host "  - Ratio: 50% SET, 50% GET (1:1)" -ForegroundColor Gray
Write-Host "  - Data size: 256 bytes" -ForegroundColor Gray
Write-Host ""

Write-Host "Monitoring benchmark progress..." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop monitoring (job will continue running)" -ForegroundColor Gray
Write-Host ""

# Monitor job status
$startTime = Get-Date
while ($true) {
    $job = kubectl get job $JOB_NAME -n $NAMESPACE -o json 2>$null | ConvertFrom-Json
    
    if ($job) {
        $active = if ($job.status.active) { $job.status.active } else { 0 }
        $succeeded = if ($job.status.succeeded) { $job.status.succeeded } else { 0 }
        $failed = if ($job.status.failed) { $job.status.failed } else { 0 }
        
        $elapsed = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
        
        Write-Host "`r[${elapsed}s] Running: $active | Completed: $succeeded/4 | Failed: $failed" -NoNewline
        
        if ($succeeded -eq 4) {
            Write-Host ""
            Write-Host ""
            Write-Host "Benchmark completed successfully!" -ForegroundColor Green
            break
        }
        
        if ($failed -gt 0) {
            Write-Host ""
            Write-Host ""
            Write-Host "WARNING: Some pods failed!" -ForegroundColor Red
            break
        }
    }
    
    Start-Sleep -Seconds 2
}

Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Benchmark Results" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

# Get pod names
$pods = kubectl get pods -n $NAMESPACE -l app=redis-benchmark -o json | ConvertFrom-Json

Write-Host "Collecting results from $($pods.items.Count) pods..." -ForegroundColor Yellow
Write-Host ""

foreach ($pod in $pods.items) {
    $podName = $pod.metadata.name
    Write-Host "=== Results from $podName ===" -ForegroundColor Cyan
    
    # Get logs from completed pod
    $logs = kubectl logs $podName -n $NAMESPACE 2>$null
    
    if ($logs) {
        # Extract summary lines
        $logs | Select-String -Pattern "Totals|Type|GET|SET|Ops/sec|Hits/sec|Latency" | ForEach-Object {
            Write-Host $_.Line -ForegroundColor Gray
        }
    } else {
        Write-Host "No logs available" -ForegroundColor Red
    }
    
    Write-Host ""
}

Write-Host ""
Write-Host "Benchmark Summary Commands:" -ForegroundColor Cyan
Write-Host "  kubectl logs -l app=redis-benchmark -n $NAMESPACE --tail=50" -ForegroundColor Gray
Write-Host "  kubectl get job $JOB_NAME -n $NAMESPACE" -ForegroundColor Gray
Write-Host ""

Write-Host "To delete benchmark job:" -ForegroundColor Cyan
Write-Host "  kubectl delete job $JOB_NAME -n $NAMESPACE" -ForegroundColor Gray
Write-Host ""
