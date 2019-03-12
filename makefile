DATE=$(shell date +%Y-%m-%d)

all: build

build: build-10.1 build-10.2 build-10.3
push: push-10.1 push-10.2 push-10.3

10.1: build-10.1 push-10.1
10.2: build-10.2 push-10.2
10.3: build-10.3 push-10.3

build-10.1:
	docker build --pull -f Dockerfile-10.1 . -t colinmollenhour/mariadb-galera-swarm:10.1-$(DATE)
test-10.1:
	./test.sh colinmollenhour/mariadb-galera-swarm:10.1-$(DATE)
push-10.1:
	docker push colinmollenhour/mariadb-galera-swarm:10.1-$(DATE)


build-10.2:
	docker build --pull . -t colinmollenhour/mariadb-galera-swarm:10.2-$(DATE)
test-10.2:
	./test.sh colinmollenhour/mariadb-galera-swarm:10.2-$(DATE)
push-10.2:
	docker push colinmollenhour/mariadb-galera-swarm:10.2-$(DATE)


build-10.3:
	docker build --pull -f Dockerfile-10.3 . -t colinmollenhour/mariadb-galera-swarm:10.3-$(DATE)
test-10.3:
	./test.sh colinmollenhour/mariadb-galera-swarm:10.3-$(DATE)
push-10.3:
	docker push colinmollenhour/mariadb-galera-swarm:10.3-$(DATE)
