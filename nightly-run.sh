#!/bin/bash
# This bash script holds the commands to start
# a new dataload and run the standard tsung suite.

# Configuration

# Whether or not the app and db servers should be reset?
START_CLEAN_APP=true
START_CLEAN_DB=true

LOG_DIR=/var/www/`date +"%Y/%m/%d/%H/%M"`
TEST_LABEL=$1

LOAD_NR_OF_BATCHES=10
LOAD_NR_OF_CONCURRENT_BATCHES=5
LOAD_NR_OF_USERS=1000
LOAD_NR_OF_GROUPS=2000
LOAD_NR_OF_CONTENT=5000

# Admin host
ADMIN_HOST='admin.oae-performance.sakaiproject.org'
# Tenant host
TENANT_HOST='cam.oae-performance.sakaiproject.org'
TENANT_ALIAS='cam'

# Circonus configuration
CIRCONUS_AUTH_TOKEN="46c8c856-5912-4da2-c2b7-a9612d3ba949"
CIRCONUS_APP_NAME="oae-nightly-run"

APP_REMOTE='sakaiproject'
APP_BRANCH='master'

# Increase the number of open files we can have.
prctl -t basic -n process.max-file-descriptor -v 32678 $$

# Log everything
mkdir -p ${LOG_DIR}
exec &> "${LOG_DIR}/nightly.txt"


if $START_CLEAN_DB ; then
        echo 'Cleaning the DB servers...'

        # Clean up the performance environment.
        # This involves ssh'ing into each machine and running the respective
        # clean scripts.

        # Clean the db nodes first.
        # Stop the entire cassandra cluster
        # Run this first so we don't run the risk that the 2 other nodes start distributing data of the first node
        ssh -t root@10.112.4.124 /sbin/service cassandra stop
        ssh -t root@10.112.4.125 /sbin/service cassandra stop
        ssh -t root@10.112.4.126 /sbin/service cassandra stop

        # Wipe data of each cassandra node
        # A snapshot will restore about 40 batches worth of data.
        ssh -t root@10.112.4.124 /root/puppet-hilary/clean-scripts/dbnode.sh
        ssh -t root@10.112.4.125 /root/puppet-hilary/clean-scripts/dbnode.sh
        ssh -t root@10.112.4.126 /root/puppet-hilary/clean-scripts/dbnode.sh
fi

if $START_CLEAN_APP ; then
        echo 'Cleaning the APP servers...'

        # Set the branch and user for this test
        ssh -t admin@10.112.4.121 "sed -i '' \"s/\\\$app_git_user .*/\\\$app_git_user = '$APP_REMOTE'/g\" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp"
        ssh -t admin@10.112.4.121 "sed -i '' \"s/\\\$app_git_branch .*/\\\$app_git_branch = '$APP_BRANCH'/g\" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp"
        ssh -t admin@10.112.4.122 "sed -i '' \"s/\\\$app_git_user .*/\\\$app_git_user = '$APP_REMOTE'/g\" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp"
        ssh -t admin@10.112.4.122 "sed -i '' \"s/\\\$app_git_branch .*/\\\$app_git_branch = '$APP_BRANCH'/g\" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp"

        # Clean the app nodes.
        # Because npm requires all sorts of things we source the .profile
        # so the PATH variable gets set.
        ssh -t admin@10.112.4.121 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"
        # sleep a bit so the keyspace creation goes trough (in case we need one)
        sleep 5
        ssh -t admin@10.112.4.122 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"

        # Sleep a bit so nginx can catch up
        sleep 10
        # Do a fake request to nginx to poke the balancers
        curl http://${ADMIN_HOST}
        curl http://${TENANT_HOST}
fi

# Flush redis.
ssh -t admin@10.112.2.103 "echo flushdb | redis-cli"


# Get an admin session to play with.
ADMIN_COOKIE=$(curl -s --cookie-jar - -d"username=administrator" -d"password=administrator" http://${ADMIN_HOST}/api/auth/login | grep connect.sid | cut -f 7)

# Create a tenant.
# In case we start from a snapshot, this will fail.
curl --cookie connect.sid=${ADMIN_COOKIE} -d"alias=${TENANT_ALIAS}" -d"name=Cambridge" -d"host=${TENANT_HOST}" http://${ADMIN_HOST}/api/tenant/create

# Turn reCaptcha checking off.
curl --cookie connect.sid=${ADMIN_COOKIE} -d"oae-principals/recaptcha/enabled=false" http://${ADMIN_HOST}/api/config








# Model loader
cd ~/OAE-model-loader
rm -rf scripts/*
git pull origin Hilary
npm update





# Generate data.
START=`date +%s`
echo "Data generation started at: " `date`
node generate.js -b ${LOAD_NR_OF_BATCHES} -t ${TENANT_ALIAS} -u ${LOAD_NR_OF_USERS} -g ${LOAD_NR_OF_GROUPS} -c ${LOAD_NR_OF_CONTENT} >> ${LOG_DIR}/generate.txt 2>&1
tar cvzf scripts.tar.gz scripts
mv scripts.tar.gz ${LOG_DIR}
END=`date +%s`
GENERATION_DURATION=$(($END - $START));
curl -H "X-Circonus-Auth-Token: ${CIRCONUS_AUTH_TOKEN}" -H "X-Circonus-App-Name: ${CIRCONUS_APP_NAME}" -d"annotations=[{\"title\": \"Data generation\", \"description\": \"Generating fake users, groups, content\", \"category\": \"nightly\", \"start\": ${START}, \"stop\": ${END} }]"  https://circonus.com/api/json/annotation
echo "Data generation ended at: " `date`




# Load it up
START=`date +%s`
echo "Load started at: " `date`
node loaddata.js -s 0 -b ${LOAD_NR_OF_BATCHES} -c ${LOAD_NR_OF_CONCURRENT_BATCHES} -h http://${TENANT_HOST} > ${LOG_DIR}/loaddata.txt 2>&1
END=`date +%s`
LOAD_DURATION=$(($END - $START));
LOAD_REQUESTS=$(grep 'Requests made:' ${LOG_DIR}/loaddata.txt | tail -n 1 | cut -f 3 -d " ");
curl -H "X-Circonus-Auth-Token: ${CIRCONUS_AUTH_TOKEN}" -H "X-Circonus-App-Name: ${CIRCONUS_APP_NAME}" -d"annotations=[{\"title\": \"Data load\", \"description\": \"Loading the generated data into the system.\", \"category\": \"nightly\", \"start\": ${START}, \"stop\": ${END} }]"  https://circonus.com/api/json/annotation
echo "Load ended at: " `date`


# Sleep a bit so that all files are closed.
sleep 30


# Generate a tsung suite
cd ~/node-oae-tsung
git pull
npm update
mkdir -p ${LOG_DIR}/tsung
node main.js -a /root/oae-nightly-stats/answers.json -s /root/OAE-model-loader/scripts -b ${LOAD_NR_OF_BATCHES} -o ${LOG_DIR}/tsung >> ${LOG_DIR}/package.txt 2>&1


# Capture some graphs.
ssh -n -f admin@10.112.4.121 ". ~/.profile && nohup sh -c /home/admin/flamegraphs.sh > /dev/null 2>&1 &"

# Run the tsung tests.
START=`date +%s`
echo "Starting tsung suite at" `date`
cd ${LOG_DIR}/tsung
tsung -f tsung.xml -l ${LOG_DIR}/tsung start > ${LOG_DIR}/tsung/run.txt 2>&1
# Tsung appends a YYYMMDD-HHmm to the specified log dir,
# grep it out so we can run the stats
TSUNG_LOG_DIR=$(grep -o '/var/www[^"]*' $LOG_DIR/tsung/run.txt)
cd $TSUNG_LOG_DIR
touch "${TEST_LABEL}.label"
/opt/local/lib/tsung/bin/tsung_stats.pl
END=`date +%s`
curl -H "X-Circonus-Auth-Token: ${CIRCONUS_AUTH_TOKEN}" -H "X-Circonus-App-Name: ${CIRCONUS_APP_NAME}" -d"annotations=[{\"title\": \"Performance test\", \"description\": \"The tsung tests hitting the various endpoints.\", \"category\": \"nightly\", \"start\": ${START}, \"stop\": ${END} }]"  https://circonus.com/api/json/annotation
echo "Tsung suite ended at " `date`


# Copy over the graphs.
scp -r admin@10.112.4.121:/home/admin/graphs ${LOG_DIR}

# Generate some simple stats.
cd ~/oae-nightly-stats
node main.js -b ${LOAD_NR_OF_BATCHES} -u ${LOAD_NR_OF_USERS} -g ${LOAD_NR_OF_GROUPS} -c ${LOAD_NR_OF_CONTENT} --generation-duration ${GENERATION_DURATION} --dataload-requests ${LOAD_REQUESTS} --dataload-duration ${LOAD_DURATION} --tsung-report ${TSUNG_LOG_DIR}/report.html > ${LOG_DIR}/stats.html