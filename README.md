oae-nightly-stats
=================

This repository holds all the scripts that are run on the nightly performance environment.
The environment consists out of:
* 3 Large (8GB RAM) centOS machines running Cassandra 1.1.5
* 2 Small (1GB RAM) SmartOS machines running the app servers
* 1 small (1GB RAM) SmartOS machine running the load balancer (nginx)

Each night the following task will be run:
1. Stop all the cassandra nodes and restore a snapshot.
   This snapshot holds 40000 users, 80000 groups and 200000 content items.
2. Stop the app nodes and redeploy latest master.
3. Generate 10 batches of which each batch holds 1000 users, 2000 groups and 5000 content items
4. Load those batches in.
5. Package the new data and generate Tsung tests (See [node-oae-tsung](https://github.com/sakaiproject/node-oae-tsung))
6. Run the tsung tests.
7. Publish all the collected data to [Circonus](http://www.circonus.com) and in the www directory of the driver machine.
8. Run a little script that provides some raw data metrics.