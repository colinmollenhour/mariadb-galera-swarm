#!/bin/bash

# Exit on errors but report line number
set -e
function err_report () {
	echo "start.sh: Trapped error on line $1"
	exit
}
trap 'err_report $LINENO' ERR

function shutdown () {
	echo "Received TERM|INT signal."
	if [[ -f /var/run/mysqld/mysqld.pid ]] && [[ -n $SYSTEM_PASSWORD ]]; then
		echo "Shutting down..."
		mariadb -u system -h 127.0.0.1 -p$SYSTEM_PASSWORD -e 'SHUTDOWN'
		# Since this is docker, expect that if we don't shut down quickly enough we will get killed anyway
	else
		exit
	fi
}
trap shutdown TERM INT

# Set 'TRACE=y' environment variable to see detailed output for debugging
if [ "$TRACE" = "y" ]; then
	set -x
fi

# Set MariaDB's time zone
if [[ -n $SKIP_TZINFO ]]; then
    # We're skipping timezone tables population, so we restrict the
    # timezone format to numeric.
    DEFAULT_TIME_ZONE=${DEFAULT_TIME_ZONE:-"+00:00"}

    if [[ $DEFAULT_TIME_ZONE != *":"* ]]; then
		echo "Timezone '$DEFAULT_TIME_ZONE' cannot be used, because 'SKIP_TZINFO' is set. Falling back to default."
        DEFAULT_TIME_ZONE="+00:00"
    fi
else
    # If we're populating timezone tables, we are able to use both verbal and
    # numeric timezone formats: "CET" or "+01:00". The first format is commonly
    # used with the `TZ` envvar, which can be overriden by a more specific
    # `DEFAULT_TIME_ZONE`.
    #
    # The default value is "+00:00".
    #
    if [[ -z $DEFAULT_TIME_ZONE ]]; then
        if [[ -n $TZ ]]; then
            DEFAULT_TIME_ZONE=$TZ
        else
            DEFAULT_TIME_ZONE="+00:00"
        fi
    fi
fi

# Set data directory permissions for later use of "gosu"
chown mysql /var/lib/mysql

#
# Utility modes
#
case "$1" in
	sleep)
		echo "Sleeping forever..."
		trap - TERM INT
		sleep infinity
		exit
		;;
	no-galera)
		echo "Starting with Galera disabled"
		shift 1

		# Allow for easily adding more startup scripts
		if [ -f /usr/local/lib/startup.sh ]; then
			source /usr/local/lib/startup.sh "$@"
		fi

		# Allow for scripts above to create a one-time use init-file
		if [ -f /var/lib/mysql/init-file.sql ]; then
			mv /var/lib/mysql/init-file.sql /tmp/init-file.sql
			set -- "$@" --init-file=/tmp/init-file.sql
		fi

		set +e -m
		gosu mysql mariadbd --console \
			--wsrep-on=OFF \
			--default-time-zone=$DEFAULT_TIME_ZONE \
			"$@" 2>&1 &
		mysql_pid=$!

		# Start fake healthcheck
		if [[ -n $FAKE_HEALTHCHECK ]]; then
			no-galera-healthcheck.sh $FAKE_HEALTHCHECK >/dev/null &
		fi

		wait $mysql_pid || true
		exit
		;;
	bash)
		shift 1
		trap - TERM INT
		exec /bin/bash "$@"
		;;
	seed|node)
		START_MODE=$1
		shift
		;;
	*)
		echo "sleep|no-galera|bash|seed|node <othernode>,..."
		exit 1
esac

#
# Resolve node address
#
if [ -z "$NODE_ADDRESS" ]; then
	# Support Weave/Kontena
	NODE_ADDRESS=$(ip addr | awk '/inet/ && /ethwe/{sub(/\/.*$/,"",$2); print $2}')
fi
if [ -z "$NODE_ADDRESS" ]; then
	# Support Docker Swarm Mode
	NODE_ADDRESS=$(ip addr | awk '/inet/ && /eth0/{sub(/\/.*$/,"",$2); print $2}' | head -n 1)
elif [[ "$NODE_ADDRESS" =~ [a-zA-Z][a-zA-Z0-9:]+ ]]; then
	# Support interface - e.g. Docker Swarm Mode uses eth0
	NODE_ADDRESS=$(ip addr | awk "/inet/ && / $NODE_ADDRESS\$/{sub(/\\/.*$/,\"\",\$2); print \$2}" | head -n 1)
elif ! [[ "$NODE_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	# Support grep pattern. E.g. ^10.0.1.*
	NODE_ADDRESS=$(getent hosts $(hostname) | awk '{print $1}' | grep -e "$NODE_ADDRESS")
fi
if ! [[ "$NODE_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "Could not determine NODE_ADDRESS: $NODE_ADDRESS"
	exit 1
fi
echo "...------======------... MariaDB Galera Start Script ...------======------..."
echo "Got NODE_ADDRESS=$NODE_ADDRESS"

MYSQL_MODE_ARGS=""

# Allow for easily adding more startup scripts
export NODE_ADDRESS
if [ -f /usr/local/lib/startup.sh ]; then
	source /usr/local/lib/startup.sh "$@"
fi

#
# Read optional secrets from files
#

# mode is xtrabackup?
if [[ $SST_METHOD =~ ^(xtrabackup|mariabackup) ]] ; then
  XTRABACKUP_PASSWORD_FILE=${XTRABACKUP_PASSWORD_FILE:-/run/secrets/xtrabackup_password}
  if [ -z $XTRABACKUP_PASSWORD ] && [ -f $XTRABACKUP_PASSWORD_FILE ]; then
	XTRABACKUP_PASSWORD=$(cat $XTRABACKUP_PASSWORD_FILE)
  fi
  [ -z "$XTRABACKUP_PASSWORD" ] && echo "WARNING: XTRABACKUP_PASSWORD is empty"
  MYSQL_MODE_ARGS+=" --wsrep_sst_auth=xtrabackup:$XTRABACKUP_PASSWORD" 
fi

SYSTEM_PASSWORD_FILE=${SYSTEM_PASSWORD_FILE:-/run/secrets/system_password}
if [ -z $SYSTEM_PASSWORD ] && [ -f $SYSTEM_PASSWORD_FILE ]; then
	SYSTEM_PASSWORD=$(cat $SYSTEM_PASSWORD_FILE)
fi
if [ -z "$SYSTEM_PASSWORD" ]; then
  if [ -n "$XTRABACKUP_PASSWORD" ]; then
     SYSTEM_PASSWORD=$(echo "$XTRABACKUP_PASSWORD" | sha256sum | awk '{print $1;}')
  else
     echo "SYSTEM_PASSWORD not set"
     exit 1
  fi
fi

CLUSTER_NAME=${CLUSTER_NAME:-cluster}
GCOMM_MINIMUM=${GCOMM_MINIMUM:-2}
GCOMM=""

# Hold startup until the flag file is deleted
if [[ -f /var/lib/mysql/hold-start ]]; then
	echo "Waiting for 'hold-start' flag file to be deleted..."
	while [[ -f /var/lib/mysql/hold-start ]]; do
		sleep 10
	done
fi

# Allow "node" to be "seed" if "new-cluster" file is present
# In this case the MYSQL_ROOT_PASSWORD may be specified within the file
if [[ $START_MODE = "node" ]] && [[ -f /var/lib/mysql/new-cluster ]]; then
	START_MODE=seed
	shift # get rid of node argument
	if [[ -s /var/lib/mysql/new-cluster ]]; then
		MYSQL_ROOT_PASSWORD="$(cat /var/lib/mysql/new-cluster)"
	fi
	rm -f /var/lib/mysql/new-cluster
fi

# Generate init file to create required users
if   ( [ "$START_MODE" = "node" ] && [ -f /var/lib/mysql/force-cluster-bootstrapping ] ) \
  || ( [ "$START_MODE" = "seed" ] && ! [ -f /var/lib/mysql/skip-cluster-bootstrapping ] )
then
	echo "Generating cluster bootstrap script..."
	MYSQL_ROOT_PASSWORD_FILE=${MYSQL_ROOT_PASSWORD_FILE:-/run/secrets/mysql_root_password}
	MYSQL_ROOT_HOST_FILE=${MYSQL_ROOT_HOST_FILE:-/run/secrets/mysql_root_host}
	MYSQL_PASSWORD_FILE=${MYSQL_PASSWORD_FILE:-/run/secrets/mysql_password}
	MYSQL_DATABASE_FILE=${MYSQL_DATABASE_FILE:-/run/secrets/mysql_database}
	if [ -z $MYSQL_ROOT_PASSWORD ] && [ -f $MYSQL_ROOT_PASSWORD_FILE ]; then
		MYSQL_ROOT_PASSWORD=$(cat $MYSQL_ROOT_PASSWORD_FILE)
	fi
	if [ -z $MYSQL_ROOT_HOST ] && [ -f $MYSQL_ROOT_HOST_FILE ]; then
		MYSQL_ROOT_HOST=$(cat $MYSQL_ROOT_HOST_FILE)
	fi
	if [ -z $MYSQL_PASSWORD ] && [ -f $MYSQL_PASSWORD_FILE ]; then
		MYSQL_PASSWORD=$(cat $MYSQL_PASSWORD_FILE)
	fi
	if [ -z $MYSQL_DATABASE ] && [ -f $MYSQL_DATABASE_FILE ]; then
		MYSQL_DATABASE=$(cat $MYSQL_DATABASE_FILE)
	fi
	if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
		MYSQL_ROOT_PASSWORD=$(head -c 32 /dev/urandom | base64 | head -c 32)
		echo "MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD"
	fi
	if [ -z "$MYSQL_ROOT_HOST" ]; then
		MYSQL_ROOT_HOST='127.0.0.1'
	fi

	>/tmp/bootstrap.sql

	# Create 'root' user
	cat >> /tmp/bootstrap.sql <<EOF
GRANT ALL PRIVILEGES ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD' WITH GRANT OPTION;
EOF
	if [ "$MYSQL_ROOT_SOCKET_AUTH" != "0" ]; then
		cat >> /tmp/bootstrap.sql <<EOF
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' IDENTIFIED VIA unix_socket WITH GRANT OPTION;
EOF
	else
		cat >> /tmp/bootstrap.sql <<EOF
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASSWORD' WITH GRANT OPTION;
EOF
	fi

	# Create 'system' user for healthchecks and shutdown signal
	cat >> /tmp/bootstrap.sql <<EOF
CREATE USER IF NOT EXISTS 'system'@'127.0.0.1' IDENTIFIED BY '$SYSTEM_PASSWORD';
GRANT PROCESS,SHUTDOWN ON *.* TO 'system'@'127.0.0.1';
CREATE USER IF NOT EXISTS 'system'@'localhost' IDENTIFIED BY '$SYSTEM_PASSWORD';
GRANT PROCESS,SHUTDOWN ON *.* TO 'system'@'localhost';
EOF

	# Create xtrabackup user if needed
	if [[ $SST_METHOD =~ ^(xtrabackup|mariabackup) ]] ; then
		cat >>/tmp/bootstrap.sql <<EOF
CREATE USER IF NOT EXISTS 'xtrabackup'@'localhost';
GRANT PROCESS,RELOAD,LOCK TABLES,REPLICATION CLIENT ON *.* TO 'xtrabackup'@'localhost';
EOF
		if [[ -n $XTRABACKUP_PASSWORD ]]; then
			cat >>/tmp/bootstrap.sql <<EOF
SET PASSWORD FOR 'xtrabackup'@'localhost' = PASSWORD('$XTRABACKUP_PASSWORD');
EOF
		fi
	fi

	# Create user's database and user
	if [ "$MYSQL_DATABASE" ]; then
		echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> /tmp/bootstrap.sql
	fi

	if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
		echo "CREATE USER IF NOT EXISTS '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" >> /tmp/bootstrap.sql
		if [ "$MYSQL_DATABASE" ]; then
			echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" >> /tmp/bootstrap.sql
		fi
	fi
	echo "FLUSH PRIVILEGES;" >> /tmp/bootstrap.sql

	# Add additional database initialization scripts
        for f in /docker-entrypoint-initdb.d/*; do
                case "$f" in
                        *.sh)     echo "$0: running $f"; . "$f" ;;
                        *.sql)    echo "$0: appending $f"; cat "$f" >> /tmp/bootstrap.sql ;;
                        *.sql.gz) echo "$0: appending $f"; gunzip -c "$f" >> /tmp/bootstrap.sql ;;
                        *)        echo "$0: ignoring $f" ;;
                esac
                echo
        done

	MYSQL_MODE_ARGS+=" --init-file=/tmp/bootstrap.sql"
	rm -f /var/lib/mysql/force-cluster-bootstrapping
	touch /var/lib/mysql/skip-cluster-bootstrapping
fi

#
# Start modes:
#  - seed - Start a new cluster - run only once and use 'node' after cluster is started
#  - node - Join an existing cluster
#
case $START_MODE in
	seed)
		MYSQL_MODE_ARGS+=" --wsrep-on=ON --wsrep-new-cluster --wsrep-sst-method=$SST_METHOD"
		echo "Starting seed node"
	;;
	node)
		ADDRS="$1"
		shift
		if [[ -z $ADDRS ]]; then
			echo "List of nodes addresses/hostnames required"
			exit 1
		fi
		MYSQL_MODE_ARGS+=" --wsrep-on=ON --wsrep-sst-method=$SST_METHOD"
		RESOLVE=0
		SLEEPS=0

		# Begin service discovery of other node addresses
		while true; do
			# Allow user to touch flag file during startup
			if [[ -f /var/lib/mysql/new-cluster ]]; then
				MYSQL_MODE_ARGS+=" --wsrep-new-cluster"
				echo "Found 'new-cluster' flag file. Starting new cluster."
				rm -f /var/lib/mysql/new-cluster
				break
			fi
			SEP=""
			GCOMM=""
			for ADDR in ${ADDRS//,/ }; do
				if [[ "$ADDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
					GCOMM+="$SEP$ADDR"
				else
					RESOLVE=1
					GCOMM+="$SEP$(getent hosts "$ADDR" | awk -v addr="$ADDR" '$2 == addr { print $1 }' | paste -sd ",")"
				fi
				if [ -n "$GCOMM" ]; then
					SEP=,
				fi
			done
			GCOMM=$(echo "$GCOMM" | sed 's/[, ]\+/,/g') # strip duplicate commas and whitespace
			GCOMM=${GCOMM#,} # strip leading commas
			GCOMM=${GCOMM%,} # strip trailing commas

			echo "Found Servers: $GCOMM"

			# Allow user to bypass waiting for other IPs
			if [[ -f /var/lib/mysql/skip-gcomm-wait ]]; then
				break
			fi

			# It is possible that containers on other nodes aren't running yet and should be waited on
			# before trying to start. For example, this occurs when updated container images are being pulled
			# by `docker service update <service>` or on a full cluster power loss
			COUNT=$(echo "$GCOMM" | tr ',' "\n" | sort -u | grep -v -e "^$NODE_ADDRESS\$" -e '^$' | wc -l)
			if [ $RESOLVE -eq 1 ] && [ $COUNT -lt $(($GCOMM_MINIMUM - 1)) ]; then

				# Bypass healthcheck so we can keep waiting for other nodes to appear
				if [[ $HEALTHY_WHILE_BOOTING -eq 1 ]]; then
					touch /var/lib/mysql/pre-boot.flag
				fi

				echo "Waiting for at least $GCOMM_MINIMUM IP addresses to resolve..."
				SLEEPS=$((SLEEPS + 1))
				sleep 3
			else
				break
			fi

			# After 90 seconds reduce GCOMM_MINIMUM
			if [ $SLEEPS -ge 30 ]; then
				SLEEPS=0
				GCOMM_MINIMUM=$((GCOMM_MINIMUM - 1))
				echo "Reducing GCOMM_MINIMUM to $GCOMM_MINIMUM"
			fi
		done
		# Pre-boot completed
		rm -f /var/lib/mysql/pre-boot.flag
		echo "Starting node, connecting to gcomm://$GCOMM"
	;;
esac


# start processes
set +e -m

# Allow external processes to write to docker logs (wsrep_notify_cmd)
# Place it in a directory that is not writeable by mariadb to prevent SST script from deleting it
fifo=/tmp/mysql-console/fifo
rm -rf $(dirname $fifo) \
  && mkdir -p $(dirname $fifo) \
  && chmod 755 $(dirname $fifo) \
  && mkfifo $fifo \
  && chmod o+rw $fifo \
  && echo "Tailing $fifo..." \
  && tail -f $fifo &
tail_pid=$!

# Port 8080 only reports healthy when ready to serve clients
# Use this one for load balancer health checks
galera-healthcheck -user=system -password="$SYSTEM_PASSWORD" \
	-port=8080 \
	-availWhenDonor=false \
	-availWhenReadOnly=false \
	-pidfile=/var/run/galera-healthcheck-1.pid >/dev/null &

# Port 8081 reports healthy as long as the server is synced or donor/desynced state
# Use this one to help other nodes determine cluster state before launching server
galera-healthcheck -user=system -password="$SYSTEM_PASSWORD" \
	-port=8081 \
	-availWhenDonor=true \
	-availWhenReadOnly=true \
	-pidfile=/var/run/galera-healthcheck-2.pid >/dev/null &

# Run automated upgrades
if [[ -z $SKIP_UPGRADES ]] && [[ ! -f /var/lib/mysql/skip-upgrades ]]; then
	sleep 5 && run-upgrades.sh || true &
fi

gosu mysql mysqld.sh --console \
	$MYSQL_MODE_ARGS \
	--wsrep_cluster_name=$CLUSTER_NAME \
	--wsrep_cluster_address=gcomm://${GCOMM%,} \
	--wsrep_node_address=$NODE_ADDRESS \
	--default-time-zone=$DEFAULT_TIME_ZONE \
	"$@" 2>&1 &

wait $! || true
RC=$?

echo "MariaDB exited with return code ($RC)"
test -f /var/lib/mysql/grastate.dat && cat /var/lib/mysql/grastate.dat

test -s /var/run/galera-healthcheck-1.pid && kill $(cat /var/run/galera-healthcheck-1.pid)
test -s /var/run/galera-healthcheck-2.pid && kill $(cat /var/run/galera-healthcheck-2.pid)

echo "Goodbye"
exit $RC
