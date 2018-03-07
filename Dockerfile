FROM mariadb:10.1.31

ENV MAXSCALE_USER=maxscale \
    MAXSCALE_PASS=maxscalepass

RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
      curl \
      netcat \
      patch \
      pigz \
      percona-toolkit \
      pv \
    && curl -sSL -o /tmp/qpress.tar http://www.quicklz.com/qpress-11-linux-x64.tar \
    && tar -C /usr/local/bin -xf /tmp/qpress.tar qpress \
    && chmod +x /usr/local/bin/qpress \
    && rm -rf /tmp/* /var/cache/apk/* /var/lib/apt/lists/*

COPY conf.d/*                /etc/mysql/conf.d/
COPY *.sh                    /usr/local/bin/
COPY bin/galera-healthcheck  /usr/local/bin/galera-healthcheck
COPY primary-component.sql   /

# Fix MDEV-15254 and MDEV-15128
COPY *.patch                 /
RUN patch /usr/bin/wsrep_sst_xtrabackup-v2 </mdev-15254.patch && rm -f /mdev-15254.patch
RUN patch /usr/bin/wsrep_sst_common </mdev-15128.patch && rm -f /mdev-15128.patch


COPY scripts/ /docker-entrypoint-initdb.d/.

# Fix permissions
RUN chown -R mysql:mysql /etc/mysql && chmod -R go-w /etc/mysql  && chown mysql:mysql /usr/local/bin/mysqld.sh && chown mysql.mysql /docker-entrypoint-initdb.d/*

EXPOSE 3306 4444 4567 4567/udp 4568 8080 8081

HEALTHCHECK CMD /usr/local/bin/healthcheck.sh

ENV SST_METHOD=xtrabackup-v2

ENTRYPOINT ["start.sh"]
