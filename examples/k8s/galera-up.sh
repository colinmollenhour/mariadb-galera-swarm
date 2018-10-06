#!/bin/bash
echo Checking secrets
./create-secrets.sh
echo Creating new k8s namespace
kubectl apply -f galera-namespace.yaml
echo Adding secrets to k8s
kubectl create secret generic -n galera galera-secrets --from-file=.secrets/xtrabackup_password --from-file=.secrets/mysql_password --from-file=.secrets/mysql_root_password
echo Adding service to k8s
kubectl apply -f service.yaml
echo Adding seed to deployment
kubectl apply -f seed-deployment.yaml
echo Please wait seed to boot properly, then start nodes with:
echo kubectl apply -f seed-deployment.yaml
