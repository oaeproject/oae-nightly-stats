#!/bin/bash
#
# This script will generate a couple of flamegraphs
# and should be placed at /home/admin/flamegraphs.sh
# on app server 0.
#

# The base directory where we will put stuff.
# This gets cleaned out on each run.
BASE=/home/admin/graphs
if [ -d "${BASE}" ] ; then
    echo "Removing ${BASE}";
    rm -rf ${BASE}
fi

mkdir -p $BASE

COUNTER=0;
# Performs all the task that are required to generate a flamegraph.
function get_graph() {
    # Get the paths where we'll store our data.
    PROFILED_DATA=${BASE}/${COUNTER}-stacks.out;
    DEMANGLED_DATA=${BASE}/${COUNTER}-demangled.out;
    GRAPH=${BASE}/${COUNTER}-graph.svg;

    # Increase the counter for the next graph.
    COUNTER=$(($COUNTER + 1));

    # Get some profiling data
    sudo dtrace -n 'profile-97/execname == "node" && arg1/{ @[jstack(150, 8000)] = count(); } tick-60s { exit(0); }' > ${PROFILED_DATA};

    # Filter out the C++ chars.
    c++filt < ${PROFILED_DATA} > ${DEMANGLED_DATA};

    # Generate the flame graph.
    /opt/local/bin/stackvis dtrace flamegraph-svg < ${DEMANGLED_DATA} > ${GRAPH};

    echo "Generated a graph at ${GRAPH}";
}


# Try to generate some graphs during peak loads
#sleep 500;
get_graph;

#sleep 1900;
get_graph;

#sleep 1600;
get_graph;