#!/bin/bash
# This bash script holds the commands to start
# a new dataload and run the standard tsung suite.

# Configuration

# Whether or not the app and db servers should be reset?

ADMIN_HOST='global.oae-performance.sakaiproject.org'
TENANT_HOST='cam.oae-performance.sakaiproject.org'

PUPPET_REMOTE='sakaiproject'
PUPPET_BRANCH='monday-demo'

APP_REMOTE='sakaiproject'
APP_BRANCH='master'

UX_REMOTE='sakaiproject'
UX_BRANCH='Hilary'

# Increase the number of open files we can have.
prctl -t basic -n process.max-file-descriptor -v 32678 $$

######################
## HELPER FUNCTIONS ##
######################

function refreshApp {
  # $1 : Host IP
  # $2 : Node name (e.g., app0)
  
  ssh -t admin@$1 << EOF
    svcadm disable node-sakai-oae;
    sudo rm -Rf /opt/oae;
    sudo rm -Rf /opt/3akai-ux;
    sudo rm -Rf puppet-hilary;
    git clone http://github.com/${PUPPET_REMOTE}/puppet-hilary;
    cd puppet-hilary;
    echo "$2" > .node
    echo performance > .environment;
    git checkout ${PUPPET_BRANCH};
    
    sed -i '' "s/\\\$app_git_user .*/\\\$app_git_user = '$APP_REMOTE'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
    sed -i '' "s/\\\$app_git_branch .*/\\\$app_git_branch = '$APP_BRANCH'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
    sed -i '' "s/\\\$ux_git_user .*/\\\$ux_git_user = '$UX_REMOTE'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
    sed -i '' "s/\\\$ux_git_branch .*/\\\$ux_git_branch = '$UX_BRANCH'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
    
    bin/pull.sh;
    sudo bin/apply.sh;
    sudo prctl -r -t basic -n process.max-file-descriptor -v 32768 -i process `pgrep node`;
EOF

}

function refreshWeb {
  # $1 : Host IP
  # $2 : Node Cert Name (e.g., web0)

  # switch the branch to the desired one in the init.pp script
  ssh -t admin@$1 << EOF
    sudo rm -Rf /opt/3akai-ux;
    sudo rm -Rf puppet-hilary;
    git clone http://github.com/${PUPPET_REMOTE}/puppet-hilary;
    cd puppet-hilary;
    echo "$2" > .node
    echo performance > .environment;
    git checkout ${PUPPET_BRANCH};

    sudo chown -R admin ~/puppet-hilary
    sed -i '' "s/\\\$ux_git_user .*/\\\$ux_git_user = '$UX_REMOTE'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
    sed -i '' "s/\\\$ux_git_branch .*/\\\$ux_git_branch = '$UX_BRANCH'/g" ~/puppet-hilary/environments/performance/modules/localconfig/manifests/init.pp;
    bin/pull.sh
    sudo bin/apply.sh
EOF

}

refreshApp 10.112.4.121 app0
refreshApp 10.112.4.122 app1
refreshApp 10.112.5.18 app2
refreshApp 10.112.4.244 app3
refreshApp 10.112.6.23 app4
refreshApp 10.112.6.24 app5
refreshApp 10.112.6.25 app6
refreshApp 10.112.6.26 app7

refreshWeb 10.112.4.123 web0

# Do a fake request to nginx to poke the balancers
curl http://${ADMIN_HOST}
curl http://${TENANT_HOST}

