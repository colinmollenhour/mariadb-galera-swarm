#!/bin/bash
#
# This script tries to start mysqld with the right parameters to join an existing cluster
# or create a new one if the old one cannot be joined
#

LOG_MESSAGE="===|mysqld.sh|===:"
OPT="$@"
HEAD_START=15
echo $OPT

function do_install_db {
	if ! test -d /var/lib/mysql/mysql; then
		echo "${LOG_MESSAGE} Initializing MariaDb data directory..."
		if ! mysql_install_db --rpm; then
			echo "${LOG_MESSAGE} Failed to initialize data directory."
			exit 1
		fi

		# Start temporary server with no networking for loading tzinfo
		if [[ -n $SKIP_TZINFO ]]; then return 0; fi
		echo "${LOG_MESSAGE} Loading timezone info..."
		mysqld --skip-networking --skip-grant-tables --socket=/tmp/mysql.sock &
		local pid=$!
		sleep 3
		mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql --protocol=socket -uroot -hlocalhost --socket=/tmp/mysql.sock mysql
		if ! kill -s TERM $pid || ! wait $pid; then
			echo "${LOG_MESSAGE} Loading tzinfo failed."
			exit 1
		fi
	fi
	return 0
}

function check_nodes {
	for node in ${1//,/ }; do
		[ "$node" = "$2" ] && continue
		if curl -f -s -o - http://$node:8081 && echo; then
			echo "${LOG_MESSAGE} Node at $node is healthy!"
			return 0
		fi
	done
	return 1
}

function prepare_bootstrap {
	[[ "$OPT" =~ --wsrep-new-cluster ]] || START="--wsrep-new-cluster"
	if [[ -n $POSITION ]]; then
		START="--wsrep_start_position=$POSITION $START"
	fi
	OPT=$(<<<$OPT sed 's#\(--wsrep_cluster_address=gcomm://\)[0-9,.]*#\1#')
	if [[ -f /var/lib/mysql/grastate.dat ]]; then
		sed -i -e 's/^safe_to_bootstrap: *0/safe_to_bootstrap: 1/' /var/lib/mysql/grastate.dat
	fi
}

function fatal_error {
	echo "${LOG_MESSAGE} Refusing to start since something is seriously wrong.."
	echo "${LOG_MESSAGE} Touch /var/lib/mysql/new-cluster to force a node to start a new cluster."
	echo "${LOG_MESSAGE} "
	echo "${LOG_MESSAGE}       VvVvVv         "
	echo "${LOG_MESSAGE}       |-  -|    //   "
	echo "${LOG_MESSAGE}  <----|O  O|---<<<   "
	echo "${LOG_MESSAGE}       |  D |    \\\\ "
	echo "${LOG_MESSAGE}       | () |         "
	echo "${LOG_MESSAGE}        \\__/         "
	echo "${LOG_MESSAGE} "
	rm -f /var/lib/mysql/auto-recovery.flag
	exit 1
}

# Set 'TRACE=y' environment variable to see detailed output for debugging
if [ "$TRACE" = "y" ]; then
	set -x
fi

if [[ "$OPT" =~ --wsrep-new-cluster ]]
then
	# --wsrep-new-cluster is used for the "seed" command so no recovery used
	echo "${LOG_MESSAGE} Starting a new cluster..."
	do_install_db
	prepare_bootstrap

elif ! test -f /var/lib/mysql/ibdata1
then
	# Skip recovery on empty data directory
	echo "${LOG_MESSAGE} No ibdata1 found, starting a fresh node..."
	do_install_db

else
	# Try to recover state from grastate.dat or logfile
	if [[ $HEALTHY_WHILE_BOOTING -eq 1 ]]; then
		touch /var/lib/mysql/auto-recovery.flag
	fi
	POSITION=''
	SAFE_TO_BOOTSTRAP=-1
	if ! test -f /var/lib/mysql/grastate.dat; then
		echo "${LOG_MESSAGE} Missing grastate.dat file..."
	elif ! grep -q 'seqno:' /var/lib/mysql/grastate.dat; then
		echo "${LOG_MESSAGE} Invalid grastate.dat file..."
	elif grep -q '00000000-0000-0000-0000-000000000000' /var/lib/mysql/grastate.dat; then
		echo "${LOG_MESSAGE} uuid is not known..."
	else
		uuid=$(awk '/^uuid:/{print $2}' /var/lib/mysql/grastate.dat)
		seqno=$(awk '/^seqno:/{print $2}' /var/lib/mysql/grastate.dat)
		SAFE_TO_BOOTSTRAP=$(awk '/^safe_to_bootstrap:/{print $2}' /var/lib/mysql/grastate.dat)
		if [ "$seqno" = "-1" ]; then
			echo "${LOG_MESSAGE} uuid is known but seqno is not..."
		elif [ -n "$uuid" ] && [ -n "$seqno" ]; then
			POSITION="$uuid:$seqno"
			echo "${LOG_MESSAGE} Recovered position from grastate.dat: $POSITION"
			echo "${LOG_MESSAGE} Safe to bootstrap: $SAFE_TO_BOOTSTRAP"
		else
			echo "${LOG_MESSAGE} The grastate.dat file appears to be corrupt:"
			echo "##########################"
			cat /var/lib/mysql/grastate.dat
			echo "##########################"
		fi
	fi

	if [[ -z $POSITION ]]; then
		echo "${LOG_MESSAGE} --------------------------------------------------"
		echo "${LOG_MESSAGE} Attempting to recover GTID positon..."

		tmpfile=$(mktemp -t wsrep_recover.XXXXXX)
		mysqld  --wsrep-on=ON \
				--wsrep_sst_method=skip \
				--wsrep_cluster_address=gcomm:// \
				--skip-networking \
				--wsrep-recover 2> $tmpfile
		if [ $? -ne 0 ]; then cat $tmpfile; else grep 'WSREP' $tmpfile; fi
		echo "${LOG_MESSAGE} --------------------------------------------------"

		POSITION=$(sed -n 's/.*WSREP: Recovered position:\s*//p' $tmpfile)
		rm -f $tmpfile
	fi

	NODE_ADDRESS=$(<<<$OPT sed -E 's#.*--wsrep_node_address=([0-9\.]+):4567.*#\1#')
	GCOMM=$(<<<$OPT sed -E 's#.*gcomm://([0-9\.,]+)\s+.*#\1#')

	if [[ -z $POSITION ]]
	then
		# If unable to find position then something is really wrong and cluster is possibly corrupt
		echo "${LOG_MESSAGE} We found no wsrep position!"
		fatal_error

	elif check_nodes $GCOMM $NODE_ADDRESS
	then
		# Use the galera-healthcheck server to determine if a healthy node exists
		echo "${LOG_MESSAGE} Found a healthy node! Attempting to join..."
		START="--wsrep_start_position=$POSITION"

	else
		# Communicate to other nodes to find if there is a Primary Component and if not
		# figure out who has the highest recovery position to be the bootstrapper
		LISTEN_PORT=3309
		EXPECT_NODES=3 # Ideally we have a three-node cluster. This will be adjusted down to 2 later

		if [[ -f /var/lib/mysql/gvwstate.dat ]]
		then
			# gvwstate.dat is only useful if all nodes have the same view so we will check
			VIEW_ID=$(</var/lib/mysql/gvwstate.dat awk '/^view_id:/{print $2 " " $3 " " $4}')
			GVW_MEMBERS=$(</var/lib/mysql/gvwstate.dat grep '^member:' | wc -l)
			echo "${LOG_MESSAGE} Found view from gvwstate.dat with ($GVW_MEMBERS) members: $VIEW_ID"
			if [[ $GVW_MEMBERS -gt $EXPECT_NODES ]]; then
				EXPECT_NODES=$GVW_MEMBERS
			fi
		fi
		if [[ $(<<<${GCOMM//,/ } wc -w) -gt $EXPECT_NODES ]]; then
			EXPECT_NODES=$(<<<${GCOMM//,/ } wc -w)
		fi
		EXPECT_NODES=$((EXPECT_NODES - 1)) # Exclude self

		# If no healthy node is running then collect uuid:seqno from other nodes and
		# use them to determine which node should do the bootstrap
		echo "${LOG_MESSAGE} Collecting grastate.dat and gvwstate.dat info from other nodes..."
		set -m
		tmpfile=$(mktemp -t socat.XXXX)
		socat -u TCP-LISTEN:$LISTEN_PORT,bind=$NODE_ADDRESS,fork OPEN:$tmpfile,append &
		PID_SERVER=$!

		# Send state data to other nodes - every 5 seconds for 3 minutes or until all nodes reached
		SENT_NODES=''
		for i in {36..0}; do
			# Allow user to touch flag file during startup
			if [[ -f /var/lib/mysql/new-cluster ]]; then
				echo "Found 'new-cluster' flag file. Starting new cluster."
				rm -f /var/lib/mysql/new-cluster
				prepare_bootstrap
				break
			fi
			for node in ${GCOMM//,/ }; do
				[[ $node = $NODE_ADDRESS ]] && continue
				if socat - TCP:$node:$LISTEN_PORT <<< "seqno:$NODE_ADDRESS:$POSITION:$SAFE_TO_BOOTSTRAP" > /dev/null; then
					SENT_NODES="$SENT_NODES,$node"
				fi
				if [[ -n $VIEW_ID ]]; then
					socat - TCP:$node:$LISTEN_PORT <<< "view:$NODE_ADDRESS:$VIEW_ID"
				fi
			done
			if   [[ $EXPECT_NODES -eq $(<$tmpfile awk -F: '/^seqno:/{print $2}' | sort -u | wc -w) ]] \
			  && [[ $EXPECT_NODES -eq $(<<<$SENT_NODES tr ',' '\n' | sort -u | wc -w) ]]
			then
				echo "${LOG_MESSAGE} Completed communication with $EXPECT_NODES other nodes."
				break
			fi

			# Check for a node coming up while we're waiting
			if check_nodes $GCOMM $NODE_ADDRESS; then
				echo "${LOG_MESSAGE} Found a healthy node, attempting to join..."
				START="--wsrep_start_position=$POSITION"
				[[ -n $VIEW_ID ]] && rm -f /var/lib/mysql/gvwstate.dat
				break
			fi

			# Merge in any nodes we have received data from so that we will also send data to them
			if [[ -s $tmpfile ]]; then
				_GCOMM="$GCOMM,$(<$tmpfile awk -F: '/^seqno:/{print $2}' | sort -u | paste -sd ',')"
				GCOMM=$(<<<"${_GCOMM%%,}" sed 's/,\+/,/g' | tr ',' '\n' | sort -u | paste -sd ',')
				OPT=$(<<<"$OPT" sed -E "s#gcomm://[0-9\\.,]+#gcomm://$GCOMM#")
			fi

			if [[ $i -eq 24 ]]; then
				echo "${LOG_MESSAGE} Could not communicate with at least $EXPECT_NODES other nodes and no nodes are up..."
				if [[ $EXPECT_NODES -gt 1 ]]; then
					EXPECT_NODES=$((EXPECT_NODES - 1))
					echo "${LOG_MESSAGE} Reducing expected nodes to $EXPECT_NODES after having waited for one minute..."
				fi
			elif [[ $i -eq 0 ]]; then
				echo "${LOG_MESSAGE} Could not communicate with at least $EXPECT_NODES other nodes and no nodes are up... Giving up!"
				fatal_error
			fi
			sleep 5
		done
		kill $PID_SERVER
		set +m

		# We now have a collection of lines for all *other* running nodes with lines like:
		#   seqno:<ip>:<uuid>:<seqno>:<safe_to_bootstrap>
		#   view:<ip>:<view_id>

		if [[ -n $START ]]
		then
			# Do nothing, we already know what to do
			true

		elif ! [[ -s $tmpfile ]]
		then
			# Did not receive communication from other nodes
			echo "${LOG_MESSAGE} No communication received from other nodes."
			fatal_error

		elif [[ -n $VIEW_ID ]]
		then
			# If all nodes have consistent views then we will maybe use gvwstate.dat to restore previous state
			NUM_VIEWS=$(<$tmpfile awk -F: "BEGIN{print \"$VIEW_ID\"} /^view:/{print \$3}" | sort -u | wc -l)
			if [ $NUM_VIEWS -eq 1 ]
			then
				LOCAL_MEMBERS=$(grep '^member:' /var/lib/mysql/gvwstate.dat | wc -l)
				TOTAL_MEMBERS=$(grep '^view:' $tmpfile | sort -u | wc -l)
				TOTAL_MEMBERS=$((TOTAL_MEMBERS + 1)) # Add 1 for self
				echo "${LOG_MESSAGE} Cluster has consistent view, checking presence of all $LOCAL_MEMBERS members..."
				if [[ $LOCAL_MEMBERS -eq $TOTAL_MEMBERS ]]; then
					# Entire cluster was shut down and restarted at once, will restore old Primary Component
					echo "${LOG_MESSAGE} gvwstate.dat file appears valid on all nodes"
					TOTAL_SEQNOS=$(<$tmpfile awk -F: "BEGIN{print \"$POSITION\"} /^seqno:/{print \$3 \":\" \$4}" | sort -u | wc -l)
					if [[ $TOTAL_SEQNOS -eq 1 ]]; then
						echo "${LOG_MESSAGE} All nodes have same seqno so using gvwstate.dat"
						START="--wsrep_start_position=$POSITION"
					else
						echo "${LOG_MESSAGE} Will not use gvwstate because mis-matching seqnos would cause SST"
						rm /var/lib/mysql/gvwstate.dat
					fi
				else
					# Not all members are present so PC cannot be restored
					echo "${LOG_MESSAGE} Not all members have gvwstate.dat file or are present"
					rm /var/lib/mysql/gvwstate.dat
				fi
			else
				echo "${LOG_MESSAGE} Cluster has more than one view, deleting gvwstate.dat"
				rm /var/lib/mysql/gvwstate.dat
			fi
		fi

		if [[ -z $START ]]
		then
			# Prefer to choose node using safe_to_bootstrap flag
			SAFE_NODES=($(<$tmpfile awk -F: '/^seqno:/{ if ($5=="1") print $2}' | sort -u))
			if [[ $SAFE_TO_BOOTSTRAP -eq 1 ]]; then
				SAFE_NODES+=($NODE_ADDRESS)
			fi
			case ${#SAFE_NODES[@]} in
				0)
					echo "${LOG_MESSAGE} No nodes are safe_to_bootstrap. Falling back to uuid/seqno method."
				;;
				1)
					if [[ ${SAFE_NODES[0]} = $NODE_ADDRESS ]]; then
						echo "${LOG_MESSAGE} This node is safe_to_bootstrap! Starting a new cluster..."
						prepare_bootstrap
					else
						echo "${LOG_MESSAGE} Another node is safe_to_bootstrap. Will attempt to join shortly..."
						START="--wsrep_start_position=$POSITION"
						sleep $HEAD_START
					fi
				;;
				*)
					echo "${LOG_MESSAGE} Multiple nodes are safe_to_bootstrap. Falling back to uuid/seqno method."
				;;
			esac
		fi

		if [[ -z $START ]]
		then
			# Otherwise we will start a new Primary Component with the best node by position
			MY_SEQNO=${POSITION#*:}
			BEST_SEQNO=$(<$tmpfile awk -F: '/^seqno:/{print $4}' | sort -nu | tail -n 1)
			echo "${LOG_MESSAGE} Comparing my seqno ($MY_SEQNO) to the best other node seqno ($BEST_SEQNO)..."
			if [ "$MY_SEQNO" -gt "$BEST_SEQNO" ]; then
				# This node is newer than all the others, start a new cluster
				echo "${LOG_MESSAGE} This node is newer than all the others. Starting a new cluster..."
				prepare_bootstrap
			elif [ "$MY_SEQNO" -lt "$BEST_SEQNO" ]; then
				# This node is older than another node, be a joiner
				echo "${LOG_MESSAGE} This node is older than another node. Will be a joiner..."
				START="--wsrep_start_position=$POSITION"
				sleep $HEAD_START
			else
				# This and another node or nodes are the newest, lowest IP wins
				LOWEST_IP=$(<$tmpfile awk -F: "/^seqno:/{ if (\$4==\"$BEST_SEQNO\") print \$2 }" | sort -u | head -n 1)
				if [ "$NODE_ADDRESS" \< "$LOWEST_IP" ]; then
					echo "${LOG_MESSAGE} This node is equal to the most advanced and has the lowest IP. Starting a new cluster..."
					prepare_bootstrap
				else
					echo "${LOG_MESSAGE} This node is the most advanced but another node ($LOWEST_IP) has a lower IP. Will be a joiner..."
					START="--wsrep_start_position=$POSITION"
					sleep $HEAD_START
				fi
			fi
		fi
	fi
	rm -f /var/lib/mysql/auto-recovery.flag
fi

# Support "truly healthy" healthchecks by listening on a new port (forwarded to the main healthcheck)
# We support TCP and HTTP healthchecks by not listening until the main healthcheck reports healthy status
if [[ $LISTEN_WHEN_HEALTHY -gt 0 ]]; then
	while true; do
		if curl -sSf -o /dev/null localhost:8080 2>/dev/null; then
			socat TCP4-LISTEN:$LISTEN_WHEN_HEALTHY,fork TCP4:localhost:8080 &
			break
		fi
		sleep 10
	done &
fi

# Start mysqld
echo "${LOG_MESSAGE} ---------------------------------------------------------------"
echo "${LOG_MESSAGE} Starting with options: $OPT $START"
exec mysqld $OPT $START

