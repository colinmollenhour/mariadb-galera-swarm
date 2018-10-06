#!/bin/sh
for file in xtrabackup_password mysql_password mysql_root_password; do
    if [ ! -f ".secrets/$file" ]; then
        echo "Generating new $file"
        openssl rand -base64 32 > ".secrets/$file"
    else
        echo "Skipping $file, already exists"
    fi
done
echo Changing permissions
chmod 600 .secrets/*
