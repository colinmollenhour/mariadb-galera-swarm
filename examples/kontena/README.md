MariaDb Galera Cluster on Kontena in 2 steps
--------------------------------------------

If you need to import a large database, uncomment the "hold-start" hook so that you can load the data
on the seed node and then remove the hold-start on each node to sync.

    $ kontena volume create --driver local --scope instance galera-data
    $ kontena stack install -n galera kontena.yml

Now import your database dump using your preferred method. The root password can be found in the docker
logs of the seed node.    

Remove the hold-start flag if you uncommented the "hold-start" hook:

    $ kontena service exec --instance 2 galera/node rm /var/lib/mysql/hold-start
    $ kontena service exec --instance 3 galera/node rm /var/lib/mysql/hold-start
