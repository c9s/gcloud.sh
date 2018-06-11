#!/bin/bash
function patch_backend_service_timeout()
{
    local project=$1
    local timeout=$2
    gcloud --project $project compute backend-services list | grep k8s-be | \
        awk '{ print $1 }' | \
        xargs -I{} gcloud --project $project compute backend-services update {} --global --timeout $timeout
}

function message()
{
    echo "$*"
}

function cache_cluster()
{
    local project=$1
    local zone=$2
    local cluster=$3
    mkdir -p cache/$project/cluster
    gcloud container clusters describe \
            --project $project \
            --zone $zone \
            --format json $cluster > cache/$project/cluster/$cluster.json
}


function cluster()
{
    local project=$1
    local cluster=$2
    if [[ -f cache/$project/cluster/$cluster.json ]]
    then
        cat cache/$project/cluster/$cluster.json
    fi
}

function cluster_num_nodes()
{
    local project=$1
    local cluster=$2
    echo $(cluster $project $cluster | jq ".currentNodeCount")
}

function install_glusterfs()
{
    local project=$1
    local zone=$2
    local cluster=$3
    local context=gke_${project}_${zone}_${cluster}

    declare -a kube_instances=()
    while read instance_id ; do
        kube_instances+=($instance_id)
    done < <(kubectl --context $context get nodes --ignore-not-found --no-headers | awk -e '{ print $1 }' | grep default)

    echo "Found kubernetes instances: ${kube_instances[@]}"
    for instance_id in "${kube_instances[@]}"
    do
        echo "$instance_id: Installing glusterf-client"
        gcloud compute ssh --project $project --zone $zone $instance_id --command "sudo apt-get update -q && sudo apt-get install -q -y glusterfs-client"

        echo "$instance_id: Labeling glusterfs=client"
        kubectl --context "$context" label --overwrite node $instance_id glusterfs=client
    done
}

# get the default-pool nodes
function kube_get_nodes()
{
    local context=$1
    shift
    kubectl --context $context get nodes --ignore-not-found --no-headers $* | awk '{ print $1 }' | grep "default"
}

function label_docker_builder_nodes()
{
    local project=$1
    local zone=$2
    local cluster=$3
    local context=gke_${project}_${zone}_${cluster}
    node_count=$(kube_get_nodes $context -l service-pool=docker-builder | perl -e 'print scalar(@_ = <>);')
    if [[ "$node_count" == "0" ]]
    then
        first_node=$(kube_get_nodes $context | head -n1)
        kubectl --context "$context" label --overwrite node $first_node service-pool=docker-builder
    fi
}


function disable_autoscaling()
{
    local project=$1
    local zone=$2
    local cluster=$3
    local pool=$4
    gcloud container clusters update $cluster --no-enable-autoscaling \
        --node-pool $pool \
        --project $project --zone $zone
}

function enable_autoscaling_default_pool()
{
    local project=$1
    local zone=$2
    local cluster=$3
    local min_nodes=$4
    local max_nodes=$5
    enable_autoscaling $project $zone $cluster "default-pool" $min_nodes $max_nodes
}

function enable_autoscaling()
{
    local project=$1
    local zone=$2
    local cluster=$3
    local pool=$4
    local min_nodes=$5
    local max_nodes=$6
    gcloud container clusters update $cluster --enable-autoscaling \
        --min-nodes $min_nodes --max-nodes $max_nodes \
        --node-pool $pool \
        --project $project --zone $zone
}

function resize_down()
{
    local project=$1
    local zone=$2
    local cluster=$3
    local request_size=$4
    local num_nodes=$(cluster_num_nodes $project $cluster)
    echo "$project/$cluster: Current $num_nodes nodes"
    echo "$project/$cluster: Request $request_size nodes"

    message "Checking $project/$cluster: I found $num_nodes nodes, and we request $request_size nodes."
    if [[ $num_nodes > $request_size ]]
    then
        message "I will now resize down $project/$cluster to $request_size nodes"
        gcloud container clusters resize --quiet --size=$request_size --project $project --zone $zone --node-pool=default-pool $cluster
    fi
    local context=gke_${project}_${zone}_${cluster}
}

function resize_up()
{
    local project=$1
    local zone=$2
    local cluster=$3
    local request_size=$4

    local num_nodes=$(cluster_num_nodes $project $cluster)

    echo "$project/$cluster: Current $num_nodes nodes"
    echo "$project/$cluster: Request $request_size nodes"
    message "Checking $project/$cluster: I found $num_nodes nodes, and we request $request_size nodes."
    if [[ $num_nodes < $request_size || "$num_nodes" == "null" ]]
    then
        message "I will now resize up $project/$cluster to $request_size nodes..."
        gcloud container clusters resize --quiet --size=$request_size --project $project --zone $zone --node-pool=default-pool $cluster || true
        sleep 5
    fi
}

function start_instance()
{
    local project=$1
    local zone=$2
    local instance=$3

    if [[ ! -e cache/$project/instance-lists ]]
    then
        mkdir -p cache/$project
        gcloud compute instances list --project $project | tail -n +2 > cache/$project/instance-lists
    fi

    # gcloud compute instances start --quiet --project $project --zone $zone $instance
    for terminated_instance in $(cat cache/$project/instance-lists | grep -i terminated | awk '{print $1}')
    do
        if [[ "$terminated_instance" == "$instance" ]]
        then
            message "I will wake up the '$instance' instance"
            gcloud compute instances start --quiet --project $project --zone $zone $instance || true
        fi
    done
}

function stop_instance()
{
    local project=$1
    local zone=$2
    local instance=$3

    if [[ ! -e cache/$project/instance-lists ]]
    then
        mkdir -p cache/$project
        gcloud compute instances list --project $project | tail -n +2 > cache/$project/instance-lists
    fi

    for running_instance in $(cat cache/$project/instance-lists | grep -i running | awk '{print $1}')
    do
        if [[ "$running_instance" == "$instance" ]]
        then
            message "I will stop the '$instance' instance..."
            gcloud compute instances stop --quiet --project $project --zone $zone $instance || true
        fi
    done
}

function stop_instances_by_pattern()
{
    local project=$1
    local zone=$2
    local pattern=$3

    message "Checking running instances for project ${project} ..."
    echo "Fetching instance list..."
    mkdir -p cache/$project
    gcloud compute instances list --project $project | tail -n +2 > cache/$project/instance-lists

    for instance in $(cat cache/$project/instance-lists | grep -i "$pattern" | grep -i running | awk '{print $1}')
    do
        message "Someone forgot to stop the instance, I will stop the '$instance' instance..."
        stop_instance $project $zone $instance
    done
}
