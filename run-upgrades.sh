#!/bin/bash

while true; do
	if [[ ! -f /var/lib/mysql/sst_in_progress ]] && curl -sf -o /dev/null localhost:8080; then
		break
	fi
	echo "$0: waiting for server to become available..."
	sleep 10
done

version=$(mysql -sNe "SELECT VERSION();")
if [[ -z $version ]]; then
	echo "$0: Could not determine MySQL version."
	exit 1
fi

FLAG=/var/lib/mysql/run-upgrades.flag
old_version=
if [[ -f $FLAG ]]; then
	old_version=$(grep -v '#' $FLAG)
fi

# Special case for 10.1 users upgrading to 10.2
if [[ -z $old_version ]]; then
	echo "$0: Granting PROCESS to xtrabackup user for old version."
	mysql -e "GRANT PROCESS ON *.* TO 'xtrabackup'@'localhost'; FLUSH PRIVILEGES;"
fi

if [[ $version != $old_version ]]; then
	echo "$0: Detected old version ($old_version -> $version)"
	echo -e "# Created by $0 on $(date)\n# DO NOT DELETE THIS FILE\n$version" > $FLAG
	mysql_upgrade
fi
