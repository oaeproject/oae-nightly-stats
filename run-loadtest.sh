#! /bin/sh

LOG_DIR=$1

echo "Starting tsung test from config file at: ${LOG_DIR}/tsung/tsung.xml"

prctl -t basic -n process.max-file-descriptor -v 32678 $$

cd ${LOG_DIR}/tsung
tsung -f tsung.xml -l ${LOG_DIR}/tsung start >> ${LOG_DIR}/tsung/run.txt 2>&1
