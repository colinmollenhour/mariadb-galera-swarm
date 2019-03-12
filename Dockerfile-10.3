FROM mariadb:10.3

# Download blocked from http://www.quicklz.com/qpress-11-linux-x64.tar
COPY bin/qpress-11-linux-x64.tar /tmp/qpress.tar

RUN set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
      curl \
      netcat \
      pigz \
      percona-toolkit \
      percona-xtrabackup \
      pv \
    && tar -C /usr/local/bin -xf /tmp/qpress.tar qpress \
    && chmod +x /usr/local/bin/qpress \
    && rm -rf /tmp/* /var/cache/apk/* /var/lib/apt/lists/*

COPY conf.d/*                /etc/mysql/conf.d/
COPY *.sh                    /usr/local/bin/
COPY bin/galera-healthcheck  /usr/local/bin/galera-healthcheck
COPY primary-component.sql   /

# Fix permissions
RUN chown -R mysql:mysql /etc/mysql && chmod -R go-w /etc/mysql

EXPOSE 3306 4444 4567 4567/udp 4568 8080 8081

HEALTHCHECK CMD /usr/local/bin/healthcheck.sh

ENV SST_METHOD=mariabackup

ENTRYPOINT ["start.sh"]
