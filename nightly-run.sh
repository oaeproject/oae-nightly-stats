#!/bin/bash
# This bash script holds the commands to start
# a new dataload and run the standard tsung suite.

# Configuration

# Whether or not the app and db servers should be reset?
START_CLEAN_APP=true
START_CLEAN_DB=true
START_CLEAN_WEB=true
START_CLEAN_SEARCH=true

RUN_DATALOAD=false

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

PUPPET_REMOTE='sakaiproject'
PUPPET_BRANCH='paris2013'

APP_REMOTE='sakaiproject'
APP_BRANCH='paris2013'

UX_REMOTE='sakaiproject'
UX_BRANCH='paris2013'

# Backend options are: 'local' or 'amazons3'
STORAGE_BACKEND='local'
STORAGE_LOCAL_DIR='/shared/files'
STORAGE_AMAZON_ACCESS_KEY='AKIAJTASR3UIC6GNWFRA'
STORAGE_AMAZON_SECRET_KEY='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'
STORAGE_AMAZON_REGION='us-east-1'
STORAGE_AMAZON_BUCKET='oae-performance-files'



# Increase the number of open files we can have.
prctl -t basic -n process.max-file-descriptor -v 32678 $$

# Log everything
mkdir -p ${LOG_DIR}
exec &> "${LOG_DIR}/nightly.txt"

######################
## HELPER FUNCTIONS ##
######################

## Refresh the puppet configuration of the server
function refreshPuppet {
        # $1 : User
        # $2 : Host IP
        # $3 : Node certName (e.g., app0)

        # Delete and re-clone puppet repository
        ssh -t $1@$2 << EOF
                rm -Rf puppet-hilary;
                git clone http://github.com/${PUPPET_REMOTE}/puppet-hilary;
                cd puppet-hilary;
                echo "$3" > .node;
                echo performance > .environment;
                git checkout ${PUPPET_BRANCH};
                bin/pull.sh;
EOF

}

## Delete and refresh the app server
function refreshApp {
        # $1 : Host IP
        # $2 : Node certName (e.g., app0)

        refreshPuppet admin $1 $2

        # switch the branch to the desired one in the init.pp script
        ssh -t admin@$1 << EOF
                sudo chown -R admin ~/puppet-hilary
                sed -i '' "s/\\\$app_git_user .*/\\\$app_git_user = '$APP_REMOTE'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
                sed -i '' "s/\\\$app_git_branch .*/\\\$app_git_branch = '$APP_BRANCH'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
                sed -i '' "s/\\\$ux_git_user .*/\\\$ux_git_user = '$UX_REMOTE'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
                sed -i '' "s/\\\$ux_git_branch .*/\\\$ux_git_branch = '$UX_BRANCH'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
                rm -rf ${STORAGE_LOCAL_DIR}/*;
EOF
        # refresh the OAE application now
        ssh -t admin@$1 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/appnode.sh"
}

function refreshActivity {
    # $1 : Host IP
    # $2 : Node certName (e.g., activity0)

    refreshApp $1 $2
}

function refreshWeb {
        # $1 : Host IP
        # $2 : Node Cert Name (e.g., web0)

        refreshPuppet admin $1 $2

        # switch the branch to the desired one in the init.pp script
        ssh -t admin@$1 << EOF
                sudo chown -R admin ~/puppet-hilary
                sed -i '' "s/\\\$ux_git_user .*/\\\$ux_git_user = '$UX_REMOTE'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
                sed -i '' "s/\\\$ux_git_branch .*/\\\$ux_git_branch = '$UX_BRANCH'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
EOF
        ssh -t admin@$1 ". ~/.profile && /home/admin/puppet-hilary/clean-scripts/webclean.sh" 
}

## Shut down the DB node
function shutdownDb {
        # $1 : Host IP
        # $2 : Node certName (e.g., app0)

        refreshPuppet root $1 $2
        ssh -t root@$1 /root/puppet-hilary/clean-scripts/dbshutdown.sh
}

## Refresh the DB node
function refreshDb {
        # $1 : Host IP

        ssh -t root@$1 /root/puppet-hilary/clean-scripts/dbclean.sh
}

## Refresh the Redis node
function refreshRedis {
        # $1 : Host IP
        # $2 : Cert Name (e.g., db0)

        refreshPuppet admin $1 $2
        ssh -t admin@$1 "echo flushdb | redis-cli"
}

function refreshSearch {
        # $1 : Host IP
        # $2 : Cert Name (e.g., search0)

        refreshPuppet root $1 $2
        ssh -t root@$1 << EOF
                cd ~/puppet-hilary
                bin/apply.sh
EOF

}

function refreshMq {
        # $1 : Host IP
        # $2 : Cert Name (e.g., mq0)
        
        refreshPuppet root $1 $2
        ssh -t root@$1 << EOF
                cd ~/puppet-hilary
                bin/apply.sh
EOF

}

## Refresh the Preview processor node.
function refreshPreviewProcessor {
        # $1 : Host IP
        # $2 : Cert Name (e.g., db0)

        refreshPuppet root $1 $2

        # switch the branch to the desired one in the init.pp script
        ssh -t root@$1 << EOF
                sed -i '' "s/\\\$app_git_user .*/\\\$app_git_user = '$APP_REMOTE'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
                sed -i '' "s/\\\$app_git_branch .*/\\\$app_git_branch = '$APP_BRANCH'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
                sed -i '' "s/\\\$ux_git_user .*/\\\$ux_git_user = '$UX_REMOTE'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
                sed -i '' "s/\\\$ux_git_branch .*/\\\$ux_git_branch = '$UX_BRANCH'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
EOF
        ssh -t root@$1 ". ~/.profile && /root/puppet-hilary/clean-scripts/ppnode.sh"
}


###############
## EXECUTION ##
###############

# Clean up the performance environment.
# This involves ssh'ing into each machine and running the respective
# clean scripts.

if $START_CLEAN_SEARCH ; then
        echo 'Cleaning the search data...'

        refreshSearch 10.112.4.222 search0
        refreshSearch 10.112.6.159 search1

        # Ensure there is a search server available with which to delete the oae index
        sleep 10

        # destroy the oae search index
        curl -XDELETE http://10.112.4.222:9200/oae
fi

if $START_CLEAN_DB ; then
        echo 'Cleaning the DB servers...'

        # Clean the db nodes first.
        # Stop the entire cassandra cluster

        # Run this first so we don't run the risk that the 2 other nodes start distributing data of the first node
        shutdownDb 10.112.4.124 db0
        shutdownDb 10.112.4.125 db1
        shutdownDb 10.112.4.126 db2
        shutdownDb 10.112.7.55 db3
        shutdownDb 10.112.3.238 db4
        shutdownDb 10.112.1.251 db5

        refreshDb 10.112.4.124
        refreshDb 10.112.4.125
        refreshDb 10.112.4.126
        refreshDb 10.112.7.55
        refreshDb 10.112.3.238
        refreshDb 10.112.1.251

fi

if $START_CLEAN_APP ; then
        echo 'Cleaning the APP servers...'

        # Refresh the first app server and give time for bootstrapping cassandra, search etc...
        refreshApp 10.112.4.121 app0
        sleep 10

        refreshApp 10.112.4.122 app1
        refreshApp 10.112.5.18 app2
        refreshApp 10.112.4.244 app3

        refreshActivity 10.112.6.85 activity0
        refreshActivity 10.112.5.198 activity1
        refreshActivity 10.112.3.29 activity2
        refreshActivity 10.112.1.113 activity3
        refreshActivity 10.112.3.83 activity4
        refreshActivity 10.112.5.207 activity5

        # Sleep a bit so nginx can catch up
        sleep 10

        refreshPreviewProcessor 10.112.6.119 pp0
fi

if $START_CLEAN_WEB ; then
        echo 'Cleaning the web server...'

        refreshWeb 10.112.4.123 web0
fi

refreshMq 10.112.5.189 mq0

# Do a fake request to nginx to poke the balancers
curl http://${ADMIN_HOST}
curl http://${TENANT_HOST}

# Flush redis.
refreshRedis 10.112.2.103 cache0

# Get an admin session to play with.
ADMIN_COOKIE=$(curl -s --cookie-jar - -d"username=administrator" -d"password=administrator" http://${ADMIN_HOST}/api/auth/login | grep connect.sid | cut -f 7)

# Create a tenant.
# In case we start from a snapshot, this will fail.
curl --cookie connect.sid=${ADMIN_COOKIE} -d"alias=${TENANT_ALIAS}" -d"name=Cambridge" -d"host=${TENANT_HOST}" http://${ADMIN_HOST}/api/tenant/create

# Turn reCaptcha checking off.
curl --cookie connect.sid=${ADMIN_COOKIE} -d"oae-principals/recaptcha/enabled=false" http://${ADMIN_HOST}/api/config

# Configure the storage backend
curl --cookie connect.sid=${ADMIN_COOKIE} -d"oae-content/default-content-copyright/defaultcopyright=nocopyright" \
  -d"oae-content/contentpermissions/defaultaccess=public" \
  -d"oae-content/documentpermissions/defaultaccess=public" \
  -d"oae-content/linkpermissions/defaultaccess=public" \
  -d"oae-content/collectionpermissions/defaultaccess=public" \
  -d"oae-content/default-content-privacy/defaultprivacy=everyone" \
  -d"oae-content/storage/backend=${STORAGE_BACKEND}" \
  -d"oae-content/storage/local-dir=${STORAGE_LOCAL_DIR}" \
  -d"oae-content/storage/amazons3-access-key=${STORAGE_AMAZON_ACCESS_KEY}" \
  -d"oae-content/storage/amazons3-secret-key=${STORAGE_AMAZON_SECRET_KEY}" \
  -d"oae-content/storage/amazons3-region=${STORAGE_AMAZON_REGION}" \
  -d"oae-content/storage/amazons3-bucket=${STORAGE_AMAZON_BUCKET}" http://${ADMIN_HOST}/api/config


if [[ ! RUN_DATALOAD ]] ; then
    echo "Running a dataload is not required. Stopping script."
    exit 0
fi


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
node main.js -a /root/oae-nightly-stats/answers.json -s /root/OAE-model-loader/scripts -b ${LOAD_NR_OF_BATCHES} -o ${LOG_DIR}/tsung -m ${TSUNG_MAX_USERS} >> ${LOG_DIR}/package.txt 2>&1


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



