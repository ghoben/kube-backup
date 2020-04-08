#!/bin/bash
# Gernot Hoebenreich (c) 2020

set +x

NAMESPACE=${MY_POD_NAMESPACE:-"kube-system"}
MY_JOB_APP_LABEL=${MY_JOB_APP_LABEL:-"kube-backup"}
MY_MAX_KEEP_LAST_JOBS_COUNT=${MY_MAX_KEEP_LAST_JOBS_COUNT:-1}

trap 'echo Error at about $LINENO' ERR

#
# Deletes the all jobs with the given label except the last MAX_KEEP_JOBS_COUNT
#
function deleteJobs() 
{
    local JOB_APP_LABEL=$1
    local MAX_KEEP_JOBS_COUNT=$2

    echo "[info] Checking jobs: app_label=${JOB_APP_LABEL} in namespace=${NAMESPACE} keep_last_jobs_count=${MAX_KEEP_JOBS_COUNT}"
    
    local JOBS
    JOBS=$(kubectl get jobs -l app="${JOB_APP_LABEL}" -n "${NAMESPACE}" -o name --sort-by=metadata.creationTimestamp)

    #The jobs are in ascending order, so we have to iterate backwards to keep the youngest ones, 
    # or use 'tao' to reverse the order

    #Determine the number of jobs, not sure why ${#JOBS[@]} is not working
    local count=0
    # shellcheck disable=SC2068
    for job in ${JOBS[@]} ; do
        count=$((count + 1))
    done

    echo "[info] Found jobs: $count "

    # shellcheck disable=SC2068
    for job in ${JOBS[@]} ; do
        if [[ $count -gt ${MAX_KEEP_JOBS_COUNT} ]]; 
        then 
            echo "[info] $count Delete job: ${job}"
            kubectl delete -n "${NAMESPACE}" "${job}"
        else
            echo "[info] $count Keep   job: ${job}"
        fi
        count=$((count - 1))
    done
}

deleteJobs "${MY_JOB_APP_LABEL}" "${MY_MAX_KEEP_LAST_JOBS_COUNT}"




