Kubernetes (k8s) Example
============

This is an example only and may not be production-quality. Please submit improvements!

Please run the following script to generate passwords for new MariaDb installation and apply initial YAMLs to k8s
```sh
galera-up.sh
```
Or if you prefer to do it manually, please execute the following commands

```sh
# Generate passwords
mkdir -p .secrets
openssl rand -base64 32 > .secrets/xtrabackup_password
openssl rand -base64 32 > .secrets/mysql_password
openssl rand -base64 32 > .secrets/mysql_root_password
chmod 600 .secrets/*

# Create new k8s namespace
kubectl apply -f galera-namespace.yaml
# Add secrets to k8s
kubectl create secret generic -n galera galera-secrets --from-file=.secrets/xtrabackup_password --from-file=.secrets/mysql_password --from-file=.secrets/mysql_root_password
# Add service to k8s
kubectl apply -f service.yaml
# Deploy Galera seed node
kubectl apply -f seed-deployment.yaml
```

Then wait for seed to boot properly and start nodes with:
```sh
kubectl apply -f seed-deployment.yaml
```
