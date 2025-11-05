#!/bin/bash

# Redis Sentinel Deployment Script
# Usage: ./deploy.sh [apply|delete]

set -e

NAMESPACE="redis-sentinel"
ACTION=${1:-apply}

echo "================================"
echo "Redis Sentinel Deployment"
echo "Action: $ACTION"
echo "Namespace: $NAMESPACE"
echo "================================"

if [ "$ACTION" = "apply" ]; then
    echo ""
    echo " Deploying Redis Sentinel..."
    
    echo " Creating namespace..."
    kubectl apply -f 00-namespace.yaml
    
    echo " Creating ConfigMaps..."
    kubectl apply -f 01-configmap-redis.yaml
    kubectl apply -f 02-configmap-sentinel.yaml
    
    echo " Creating Services..."
    kubectl apply -f 03-service.yaml
    
    echo " Deploying Redis StatefulSet..."
    kubectl apply -f 04-statefulset-redis.yaml
    
    echo " Waiting for Redis pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=redis -n $NAMESPACE --timeout=120s
    
    echo " Deploying Sentinel..."
    kubectl apply -f 05-deployment-sentinel.yaml
    
    echo " Waiting for Sentinel pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=sentinel -n $NAMESPACE --timeout=60s
    
    echo " Deploying HAProxy..."
    kubectl apply -f 07-haproxy-configmap.yaml
    kubectl apply -f 08-haproxy-deployment.yaml
    kubectl apply -f 09-haproxy-service.yaml
    
    echo " Waiting for HAProxy to be ready..."
    kubectl wait --for=condition=ready pod -l app=haproxy -n $NAMESPACE --timeout=60s
    
    echo ""
    echo "✅ Deployment complete!"
    echo ""
    echo "📊 Status:"
    kubectl get pods -n $NAMESPACE
    echo ""
    kubectl get svc -n $NAMESPACE
    
    echo ""
    echo "🧪 Quick test commands:"
    echo "  # Test via HAProxy (recommended)"
    echo "  kubectl run -it --rm redis-test --image=redis:7.2-alpine -n $NAMESPACE -- redis-cli -h redis-ha SET test 'hello'"
    echo ""
    echo "  # Check Sentinel status"
    echo "  kubectl exec -it deployment/sentinel -n $NAMESPACE -- redis-cli -p 26379 SENTINEL masters"
    echo ""
    echo "  # HAProxy stats"
    echo "  kubectl port-forward svc/haproxy-stats 8404:8404 -n $NAMESPACE"
    echo "  # Then open: http://localhost:8404"
    
elif [ "$ACTION" = "delete" ]; then
    echo ""
    echo "🗑️  Deleting Redis Sentinel..."
    
    kubectl delete -f 09-haproxy-service.yaml --ignore-not-found=true
    kubectl delete -f 08-haproxy-deployment.yaml --ignore-not-found=true
    kubectl delete -f 07-haproxy-configmap.yaml --ignore-not-found=true
    kubectl delete -f 05-deployment-sentinel.yaml --ignore-not-found=true
    kubectl delete -f 04-statefulset-redis.yaml --ignore-not-found=true
    kubectl delete -f 03-service.yaml --ignore-not-found=true
    kubectl delete -f 02-configmap-sentinel.yaml --ignore-not-found=true
    kubectl delete -f 01-configmap-redis.yaml --ignore-not-found=true
    
    echo " Waiting for pods to terminate..."
    kubectl wait --for=delete pod -l app=redis -n $NAMESPACE --timeout=60s 2>/dev/null || true
    kubectl wait --for=delete pod -l app=sentinel -n $NAMESPACE --timeout=60s 2>/dev/null || true
    
    echo " Deleting PVCs..."
    kubectl delete pvc -l app=redis -n $NAMESPACE --ignore-not-found=true
    
    echo " Deleting namespace..."
    kubectl delete -f 00-namespace.yaml --ignore-not-found=true
    
    echo ""
    echo " Cleanup complete!"
    
else
    echo "❌ Invalid action: $ACTION"
    echo "Usage: $0 [apply|delete]"
    exit 1
fi
