# Redis Sentinel Deployment Script (PowerShell)
# Usage: .\deploy.ps1 -Action [apply|delete]

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet("apply", "delete")]
    [string]$Action = "apply"
)

$NAMESPACE = "redis-sentinel"

Write-Host "================================" -ForegroundColor Cyan
Write-Host "Redis Sentinel Deployment" -ForegroundColor Cyan
Write-Host "Action: $Action" -ForegroundColor Cyan
Write-Host "Namespace: $NAMESPACE" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""

if ($Action -eq "apply") {
    Write-Host " Deploying Redis Sentinel..." -ForegroundColor Green
    Write-Host ""
    
    Write-Host " Creating namespace..." -ForegroundColor Yellow
    kubectl apply -f 00-namespace.yaml
    
    Write-Host " Creating ConfigMaps..." -ForegroundColor Yellow
    kubectl apply -f 01-configmap-redis.yaml
    kubectl apply -f 02-configmap-sentinel.yaml
    
    Write-Host " Creating Services..." -ForegroundColor Yellow
    kubectl apply -f 03-service.yaml
    
    Write-Host " Deploying Redis StatefulSet..." -ForegroundColor Yellow
    kubectl apply -f 04-statefulset-redis.yaml
    
    Write-Host " Waiting for Redis pods to be ready..." -ForegroundColor Yellow
    kubectl wait --for=condition=ready pod -l app=redis -n $NAMESPACE --timeout=120s
    
    Write-Host " Deploying Sentinel..." -ForegroundColor Yellow
    kubectl apply -f 05-deployment-sentinel.yaml
    
    Write-Host " Waiting for Sentinel pods to be ready..." -ForegroundColor Yellow
    kubectl wait --for=condition=ready pod -l app=sentinel -n $NAMESPACE --timeout=60s
    
    Write-Host " Deploying HAProxy..." -ForegroundColor Yellow
    kubectl apply -f 07-haproxy-configmap.yaml
    kubectl apply -f 08-haproxy-deployment.yaml
    kubectl apply -f 09-haproxy-service.yaml
    
    Write-Host " Waiting for HAProxy to be ready..." -ForegroundColor Yellow
    kubectl wait --for=condition=ready pod -l app=haproxy -n $NAMESPACE --timeout=60s
    
    Write-Host ""
    Write-Host " Deployment complete!" -ForegroundColor Green
    Write-Host ""
    
    Write-Host " Status:" -ForegroundColor Cyan
    kubectl get pods -n $NAMESPACE
    Write-Host ""
    kubectl get svc -n $NAMESPACE
    
    Write-Host ""
    Write-Host " Quick test commands:" -ForegroundColor Cyan
    Write-Host "  # Test via HAProxy (recommended)" -ForegroundColor Yellow
    Write-Host "  kubectl run -it --rm redis-test --image=redis:7.2-alpine -n $NAMESPACE -- redis-cli -h redis-ha SET test 'hello'" -ForegroundColor Gray
    Write-Host ""  
    Write-Host "  # Check Sentinel status" -ForegroundColor Yellow
    Write-Host "  kubectl exec -it deployment/sentinel -n $NAMESPACE -- redis-cli -p 26379 SENTINEL masters" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  # HAProxy stats" -ForegroundColor Yellow
    Write-Host "  kubectl port-forward svc/haproxy-stats 8404:8404 -n $NAMESPACE" -ForegroundColor Gray
    Write-Host "  # Then open: http://localhost:8404" -ForegroundColor Gray
    
} elseif ($Action -eq "delete") {
    Write-Host " Deleting Redis Sentinel..." -ForegroundColor Red
    Write-Host ""
    
    kubectl delete -f 09-haproxy-service.yaml --ignore-not-found=true
    kubectl delete -f 08-haproxy-deployment.yaml --ignore-not-found=true
    kubectl delete -f 07-haproxy-configmap.yaml --ignore-not-found=true
    kubectl delete -f 05-deployment-sentinel.yaml --ignore-not-found=true
    kubectl delete -f 04-statefulset-redis.yaml --ignore-not-found=true
    kubectl delete -f 03-service.yaml --ignore-not-found=true
    kubectl delete -f 02-configmap-sentinel.yaml --ignore-not-found=true
    kubectl delete -f 01-configmap-redis.yaml --ignore-not-found=true
    
    Write-Host " Waiting for pods to terminate..." -ForegroundColor Yellow
    try {
        kubectl wait --for=delete pod -l app=redis -n $NAMESPACE --timeout=60s 2>$null
        kubectl wait --for=delete pod -l app=sentinel -n $NAMESPACE --timeout=60s 2>$null
    } catch {
        # Ignore errors
    }
    
    Write-Host " Deleting PVCs..." -ForegroundColor Yellow
    kubectl delete pvc -l app=redis -n $NAMESPACE --ignore-not-found=true
    
    Write-Host " Deleting namespace..." -ForegroundColor Yellow
    kubectl delete -f 00-namespace.yaml --ignore-not-found=true
    
    Write-Host ""
    Write-Host " Cleanup complete!" -ForegroundColor Green
}

Write-Host ""
