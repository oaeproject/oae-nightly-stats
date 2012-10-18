#!/bin/bash
# This script will pull the latest oae-nightly repo and start the nightly run.
cd /root/oae-nightly-stats
git pull origin master

# Start the run
./nightly-run.sh