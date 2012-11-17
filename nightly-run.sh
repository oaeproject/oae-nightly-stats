#!/bin/bash
# This bash script holds the commands to start
# a new dataload and run the standard tsung suite.

# Functions
function switchGit {
        # $1 : Host IP
        # $2 : Git Remote
        # $3 : Git Branch

        # first reset the working copy so we can pull the newest code
        ssh -t admin@$1 "cd puppet-hilary; git reset --hard HEAD; bin/pull.sh"

        # switch the branch to the desired one
        ssh -t admin@$1 "sed -i '' \"s/\\\$app_git_user .*/\\\$app_git_user = '$2'/g\" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp"
        ssh -t admin@$1 "sed -i '' \"s/\\\$app_git_branch .*/\\\$app_git_branch = '$3'/g\" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp"

}

function cleanDb {
        # $1 : Host IP
        ssh -t root@$1 /root/puppet-hilary/clean-scripts/dbclean.sh
}

# Configuration

# Whether or not the app and db servers should be reset?
START_CLEAN_APP=true
START_CLEAN_DB=true

LOG_DIR=/var/www/`date +"%Y/%m/%d/%H/%M"`
TEST_LABEL=$1

LOAD_NR_OF_BATCHES=10
LOAD_NR_OF_CONCURRENT_BATCHES=10
LOAD_NR_OF_USERS=1000
LOAD_NR_OF_GROUPS=2000
LOAD_NR_OF_CONTENT=5000
LOAD_TENANT='cam'
LOAD_HOST='165.225.133.115'
LOAD_PORT=2001

CIRCONUS_AUTH_TOKEN="46c8c856-5912-4da2-c2b7-a9612d3ba949"
CIRCONUS_APP_NAME="oae-nightly-run"

APP_REMOTE='simong'
APP_BRANCH='usercacheperformanceMembershipsCassandra'

# Increase the number of open files we can have.
prctl -t basic -n process.max-file-descriptor -v 32678 $$

# Log everything
mkdir -p ${LOG_DIR}
exec &> "${LOG_DIR}/nightly.txt"


if $START_CLEAN_DB ; then
        echo 'Cleaning the DB servers...'

        # Wipe data of each cassandra node
        cleanDb 10.112.4.124
        cleanDb 10.112.4.125
        cleanDb 10.112.4.126
        cleanDb 10.112.3.39
        cleanDb 10.112.3.40
fi

ssh -t admin@10.112.2.103 "redis-cli flushall"

if $START_CLEAN_APP ; then
        echo 'Cleaning the APP servers...'

        switchGit 10.112.4.121 $APP_REMOTE $APP_BRANCH
        switchGit 10.112.4.122 $APP_REMOTE $APP_BRANCH
        switchGit 10.112.5.18 $APP_REMOTE $APP_BRANCH
        switchGit 10.112.4.244 $APP_REMOTE $APP_BRANCH
        switchGit 10.112.2.196 $APP_REMOTE $APP_BRANCH
        switchGit 10.112.4.33 $APP_REMOTE $APP_BRANCH
        switchGit 10.112.4.230 $APP_REMOTE $APP_BRANCH
        switchGit 10.112.5.178 $APP_REMOTE $APP_BRANCH

        # Clean the app nodes.
        # Because npm requires all sorts of things we source the .profile
        # so the PATH variable gets set.
        ssh -t admin@10.112.4.121 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"

        # sleep a bit so the keyspace creation goes trough (in case we need one)
        sleep 5

        ssh -t admin@10.112.4.122 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"
        ssh -t admin@10.112.5.18 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"
        ssh -t admin@10.112.4.244 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"
        ssh -t admin@10.112.2.196 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"
        ssh -t admin@10.112.4.33 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"
        ssh -t admin@10.112.4.230 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"
        ssh -t admin@10.112.5.178 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"

        # Sleep a bit so nginx can catch up
        sleep 10

        # Do a fake request to nginx to poke the balancers
        curl http://${LOAD_HOST}
fi


# Get an admin session to play with.
ADMIN_COOKIE=$(curl -s --cookie-jar - -d"username=administrator" -d"password=administrator" http://${LOAD_HOST}/api/auth/login | grep connect.sid | cut -f 7)

# Create a tenant.
# In case we start from a snapshot, this will fail.
curl --cookie connect.sid=${ADMIN_COOKIE} -d"id=cam" -d"name=Cambridge" -d"port=2001" -d"baseurl=t1.oae-performance.sakaiproject.org" http://${LOAD_HOST}/api/tenant/create

# Turn reCaptcha checking off.
curl --cookie connect.sid=${ADMIN_COOKIE} -d"oae-principals/recaptcha/enabled=false" http://${LOAD_HOST}/api/config








# Model loader
cd ~/OAE-model-loader
rm -rf scripts/*
git pull origin Hilary
npm update





# Generate data.
START=`date +%s`
echo "Data generation started at: " `date`
node generate.js -b ${LOAD_NR_OF_BATCHES} -t ${LOAD_TENANT} -u ${LOAD_NR_OF_USERS} -g ${LOAD_NR_OF_GROUPS} -c ${LOAD_NR_OF_CONTENT} >> ${LOG_DIR}/generate.txt 2>&1
tar cvzf scripts.tar.gz scripts
mv scripts.tar.gz ${LOG_DIR}
END=`date +%s`
GENERATION_DURATION=$(($END - $START));
curl -H "X-Circonus-Auth-Token: ${CIRCONUS_AUTH_TOKEN}" -H "X-Circonus-App-Name: ${CIRCONUS_APP_NAME}" -d"annotations=[{\"title\": \"Data generation\", \"description\": \"Generating fake users, groups, content\", \"category\": \"nightly\", \"start\": ${START}, \"stop\": ${END} }]"  https://circonus.com/api/json/annotation
echo "Data generation ended at: " `date`




# Load it up
START=`date +%s`
echo "Load started at: " `date`
node loaddata.js -s 0 -b ${LOAD_NR_OF_BATCHES} -c ${LOAD_NR_OF_CONCURRENT_BATCHES} -h http://t1.oae-performance.sakaiproject.org > ${LOG_DIR}/loaddata.txt 2>&1
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
echo "node main.js -a /root/oae-nightly-stats/answers.json -s /root/OAE-model-loader/scripts -b ${LOAD_NR_OF_BATCHES} -o ${LOG_DIR}/tsung -m 25000"
node main.js -a /root/oae-nightly-stats/answers.json -s /root/OAE-model-loader/scripts -b ${LOAD_NR_OF_BATCHES} -o ${LOG_DIR}/tsung -m 25000 >> ${LOG_DIR}/package.txt 2>&1


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


