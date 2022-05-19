Kubernetes
==========
I could not find a working galera or multi master helm chart. Stumbled upon this image with a working
docker-compose example. And decided to get it running in kubernetes. Am sharing this to say thanks to
colinmollenhour who clearly put a lots of effort in this image. I will create a helm chart from this
configuration later. If you have any improvements please submit them.


1. Generate XTRABACKUP_PASSWORD, SYSTEM_PASSWORD, MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD 
and put them in secrets.yml

```
$ openssl rand -base64 32 | base64

```

2. Verify if statefullset arg matches seed service dns name: seed,mariadb-galera-seed.default

3. Setup the cluster
```
$ kubectl create -f secrets.yml && \
  kubectl create -f service.yml && \
  kubectl create -f deployment.yml && \
  kubectl create -f statefullset.yml
```


Note! Am using the _FILE env variables because had issues with using the direct variables in
combination with kubernetes secrets.