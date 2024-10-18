#!/bin/bash

RECERT_IMAGE=${RECERT_IMAGE:-quay.io/edge-infrastructure/recert:v0}
BACKUP_DIR=/var/tmp/recert
KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig
ETCD_IMAGE=$(jq -r '.spec.containers[] | select(.name == "etcd") | .image' /etc/kubernetes/manifests/etcd-pod.yaml)

export KUBECONFIG

usage() {
    cat << EOF
Usage:
    $0 backup       Creates backup of openshift certificates
    $0 recert       Runs recert to extend expiration using backed up certificates
EOF
    exit 1
}

kube_save(){
    local type=$1
    local name=$2
    local namespace=$3
    local key=$4
    local dest_file=$5

    oc extract -n $namespace $type/$name --keys $key --to=- > "$BACKUP_DIR/$dest_file"
}

backup_cluster_certificates(){
    mkdir -p $BACKUP_DIR
    kube_save configmap admin-kubeconfig-client-ca openshift-config ca-bundle.crt admin-kubeconfig-client-ca.crt
    kube_save secret loadbalancer-serving-signer openshift-kube-apiserver-operator tls.key loadbalancer-serving-signer.key
    kube_save secret localhost-serving-signer openshift-kube-apiserver-operator tls.key localhost-serving-signer.key
    kube_save secret service-network-serving-signer openshift-kube-apiserver-operator tls.key service-network-serving-signer.key
    kube_save secret router-ca openshift-ingress-operator tls.key ingresskey-ingress-operator.key
}

run_recert(){
    local router_cn_ca=$(oc get secret -n openshift-ingress-operator router-ca -ojsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -subject -noout -nameopt multiline | grep commonName | awk '{ print $3 }')

    # Stop kubelet
    echo "Stopping kubelet"
    systemctl stop kubelet
    while systemctl is-active --quiet kubelet; do
        echo -n .
    done
    echo " done"

    # Stop running containers
    echo "Stopping containers"
    while crictl ps -q | grep -q .; do
        crictl ps -q | xargs --no-run-if-empty --max-args 1 --max-procs 10 crictl stop --timeout 5 || true
    done

    # Run etcd
    echo "Running etcd container for recert"
    sudo podman run --authfile=/var/lib/kubelet/config.json --name recert_etcd --detach --rm --network=host --privileged --replace --entrypoint etcd -v /var/lib/etcd:/store ${ETCD_IMAGE} --name editor --data-dir /store
    sleep 10

    # Run recert
    echo "Running recert"
    sudo podman run --name recert --rm --network=host --privileged --replace \
        -v $BACKUP_DIR:/certs \
        -v /etc/kubernetes:/kubernetes \
        -v /var/lib/kubelet:/kubelet \
        -v /etc/machine-config-daemon:/machine-config-daemon \
        ${RECERT_IMAGE} \
            --etcd-endpoint localhost:2379 \
            --static-dir /kubernetes \
            --static-dir /kubelet \
            --static-dir /machine-config-daemon \
            --summary-file /kubernetes/recert-summary.yaml \
            --extend-expiration \
            --use-cert /certs/admin-kubeconfig-client-ca.crt \
            --use-key "kube-apiserver-lb-signer /certs/loadbalancer-serving-signer.key" \
            --use-key "kube-apiserver-localhost-signer /certs/localhost-serving-signer.key" \
            --use-key "kube-apiserver-service-network-signer /certs/service-network-serving-signer.key" \
            --use-key "${router_cn_ca} /certs/ingresskey-ingress-operator.key"

    # Kill etcd
    echo "Stopping etcd"
    podman stop recert_etcd
    sleep 10

    # Start kubelet
    echo "Starting kubelet"
    systemctl start kubelet
}

case $1 in
    backup)
        backup_cluster_certificates ;;
    recert)
        run_recert ;;
    *)
        usage ;;
esac
