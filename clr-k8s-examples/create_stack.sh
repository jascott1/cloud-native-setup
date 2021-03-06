#!/usr/bin/env bash

###
#  create_stack.sh - Intialize a Kubernetes cluster and install components
##

set -o errexit
set -o pipefail
set -o nounset

CUR_DIR=$(pwd)
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
: ${TOKEN:=}
: ${MASTER_IP:=}
HIGH_POD_COUNT=${HIGH_POD_COUNT:-""}

# versions
CANAL_VER="${CLRK8S_CANAL_VER:-v3.9}"
K8S_VER="${CLRK8S_K8S_VER:-}"
ROOK_VER="${CLRK8S_ROOK_VER:-v1.1.1}"
METRICS_VER="${CLRK8S_METRICS_VER:-v0.3.5}"
PROMETHEUS_VER="${CLRK8S_PROMETHEUS_VER:-f458e85e5d7675f7bc253072e1b4c8892b51af0f}"

function print_usage_exit() {
	exit_code=${1:-0}
	cat <<EOT
Usage: $0 [subcommand]

Subcommands:

$(
		for cmd in "${!command_handlers[@]}"; do
			printf "\t%s:|\t%s\n" "${cmd}" "${command_help[${cmd}]:-Not-documented}"
		done | sort | column -t -s "|"
	)
EOT
	exit "${exit_code}"
}

function finish() {
	cd "${CUR_DIR}"
}
trap finish EXIT

function cluster_init() {
	# Config replacements
	if ! [ -z ${TOKEN} ]; then
		sed -i "/InitConfiguration/a bootstrapTokens:\\n- token: ${TOKEN}" ./kubeadm/base/kubeadm.yaml
	fi
	if ! [ -z ${MASTER_IP} ]; then
		sed -i "/InitConfiguration/a localAPIEndpoint:\\n  advertiseAddress: ${MASTER_IP}" ./kubeadm/base/kubeadm.yaml
	fi
	if [[ -n "$K8S_VER" && $(grep -c kubernetesVersion ./kubeadm/base/kubeadm.yaml) -eq 0 ]]; then
		sed -i "s/ClusterConfiguration/ClusterConfiguration\nkubernetesVersion: ${K8S_VER}/g" ./kubeadm/base/kubeadm.yaml
	fi
	# Config patches
	if [[ -n "${HIGH_POD_COUNT}" ]]; then
		echo "$(kubectl kustomize ./kubeadm/high-pod-count/)" > ./kubeadm/base/kubeadm.yaml
	fi
	#This only works with kubernetes 1.12+. The kubeadm.yaml is setup
	#to enable the RuntimeClass featuregate
	if [[ -d /var/lib/etcd ]]; then
		echo "/var/lib/etcd exists! skipping init."
		return
	fi
	sudo -E kubeadm init --config=./kubeadm/base/kubeadm.yaml

	rm -rf "${HOME}/.kube"
	mkdir -p "${HOME}/.kube"
	sudo cp -i /etc/kubernetes/admin.conf "${HOME}/.kube/config"
	sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"

	# skip terminal check if CLRK8S_NOPROMPT is set
	skip="${CLRK8S_NOPROMPT:-}"
	if [[ -z "${skip}" ]]; then
		# If this an interactive terminal then wait for user to join workers
		if [[ -t 0 ]]; then
			read -p "Join other nodes. Press enter to continue"
		fi
	fi

	#Ensure single node k8s works
	if [ "$(kubectl get nodes | wc -l)" -eq 2 ]; then
		kubectl taint nodes --all node-role.kubernetes.io/master-
	fi
}

function kata() {
	KATA_VER=${1:-1.8.2-kernel-config}
	KATA_URL="https://github.com/kata-containers/packaging.git"
	KATA_DIR="8-kata"
	get_repo "${KATA_URL}" "${KATA_DIR}/overlays/${KATA_VER}"
	set_repo_version "${KATA_VER}" "${KATA_DIR}/overlays/${KATA_VER}/packaging"
	kubectl apply -k "${KATA_DIR}/overlays/${KATA_VER}"

}

function cni() {
	# note version is not semver
	CANAL_VER=${1:-$CANAL_VER}
	CANAL_URL="https://docs.projectcalico.org/${CANAL_VER}/manifests"
	if [[ "$CANAL_VER" == "v3.3" ]]; then
		CANAL_URL="https://docs.projectcalico.org/v3.3/getting-started/kubernetes/installation/hosted/canal"
	fi
	CANAL_DIR="0-canal"

	# canal manifests are not kept in repo but in docs site so use curl
	mkdir -p "${CANAL_DIR}/overlays/${CANAL_VER}/canal"
	curl -o "${CANAL_DIR}/overlays/${CANAL_VER}/canal/canal.yaml" "$CANAL_URL/canal.yaml"
	if [[ "$CANAL_VER" == "v3.3" ]]; then
		curl -o "${CANAL_DIR}/overlays/${CANAL_VER}/canal/rbac.yaml" "$CANAL_URL/rbac.yaml"
	fi
	# canal doesnt pass kustomize validation
	kubectl apply -k "${CANAL_DIR}/overlays/${CANAL_VER}" --validate=false

}

function metrics() {
	METRICS_VER="${1:-$METRICS_VER}"
	METRICS_URL="https://github.com/kubernetes-incubator/metrics-server.git"
	METRICS_DIR="1-core-metrics"
	get_repo "${METRICS_URL}" "${METRICS_DIR}/overlays/${METRICS_VER}"
	set_repo_version "${METRICS_VER}" "${METRICS_DIR}/overlays/${METRICS_VER}/metrics-server"
	kubectl apply -k "${METRICS_DIR}/overlays/${METRICS_VER}"

}
function wait_on_pvc() {
	# create and destroy pvc until successful
	while [[ $(kubectl get pvc test-pv-claim --no-headers | grep Bound -c) -ne 1 ]]; do
		sleep 30
		kubectl delete pvc test-pv-claim
		create_pvc
		sleep 10
	done
}
function create_pvc() {
	kubectl apply -f - <<HERE
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pv-claim
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Mi
HERE

}

function storage() {
	# start rook before any other component that requires storage
	ROOK_VER="${1:-$ROOK_VER}"
	ROOK_URL="https://github.com/rook/rook.git"
	ROOK_DIR=7-rook

	# get and apply rook
	get_repo "${ROOK_URL}" "${ROOK_DIR}/overlays/${ROOK_VER}"
	set_repo_version "${ROOK_VER}" "${ROOK_DIR}/overlays/${ROOK_VER}/rook"
	kubectl apply -k "${ROOK_DIR}/overlays/${ROOK_VER}"
	# wait for the rook OSDs to run which means rooks should be ready
	while [[ $(kubectl get po --all-namespaces | grep -e 'osd.*Running.*' -c) -lt 1 ]]; do
		echo "Waiting for Rook OSD"
		sleep 60
	done

	# set default storageclass
	kubectl patch storageclass rook-ceph-block -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

	create_pvc
	# wait for pvc so subsequent pods have storage
	wait_on_pvc
}

function monitoring() {
	PROMETHEUS_VER=${1:-$PROMETHEUS_VER}
	PROMETHEUS_URL="https://github.com/coreos/kube-prometheus.git"
	PROMETHEUS_DIR="4-kube-prometheus"
	get_repo "${PROMETHEUS_URL}" "${PROMETHEUS_DIR}/overlays/${PROMETHEUS_VER}"
	set_repo_version "${PROMETHEUS_VER}" "${PROMETHEUS_DIR}/overlays/${PROMETHEUS_VER}/kube-prometheus"
	kubectl apply -k "${PROMETHEUS_DIR}/overlays/${PROMETHEUS_VER}"

	while [[ $(kubectl get crd alertmanagers.monitoring.coreos.com prometheuses.monitoring.coreos.com prometheusrules.monitoring.coreos.com servicemonitors.monitoring.coreos.com >/dev/null 2>&1) || $? -ne 0 ]]; do
		echo "Waiting for Prometheus CRDs"
		sleep 2
	done

	#Expose the dashboards
	#kubectl --namespace monitoring port-forward svc/prometheus-k8s 9090 &
	#kubectl --namespace monitoring port-forward svc/grafana 3000 &
	#kubectl --namespace monitoring port-forward svc/alertmanager-main 9093 &
}

function dashboard() {
	DASHBOARD_VER=${1:-v2.0.0-beta2}
	DASHBOARD_URL="https://github.com/kubernetes/dashboard.git"
	DASHBOARD_DIR="2-dashboard"
	get_repo "${DASHBOARD_URL}" "${DASHBOARD_DIR}/overlays/${DASHBOARD_VER}"
	set_repo_version "${DASHBOARD_VER}" "${DASHBOARD_DIR}/overlays/${DASHBOARD_VER}/dashboard"
	kubectl apply -k "${DASHBOARD_DIR}/overlays/${DASHBOARD_VER}"
}

function ingres() {
	INGRES_VER=${1:-nginx-0.25.1}
	INGRES_URL="https://github.com/kubernetes/ingress-nginx.git"
	INGRES_DIR="5-ingres-lb"
	get_repo "${INGRES_URL}" "${INGRES_DIR}/overlays/${INGRES_VER}"
	set_repo_version "${INGRES_VER}" "${INGRES_DIR}/overlays/${INGRES_VER}/ingress-nginx"
	kubectl apply -k "${INGRES_DIR}/overlays/${INGRES_VER}"
}

function efk() {
	EFK_VER=${1:-v1.15.1}
	EFK_URL="https://github.com/kubernetes/kubernetes.git"
	EFK_DIR="3-efk"
	get_repo "${EFK_URL}" "${EFK_DIR}/overlays/${EFK_VER}"
	set_repo_version "${EFK_VER}" "${EFK_DIR}/overlays/${EFK_VER}/kubernetes"
	kubectl apply -k "${EFK_DIR}/overlays/${EFK_VER}"

}

function metallb() {
	METALLB_VER=${1:-v0.8.1}
	METALLB_URL="https://github.com/danderson/metallb.git"
	METALLB_DIR="6-metal-lb"
	get_repo "${METALLB_URL}" "${METALLB_DIR}/overlays/${METALLB_VER}"
	set_repo_version "${METALLB_VER}" "${METALLB_DIR}/overlays/${METALLB_VER}/metallb"
	kubectl apply -k "${METALLB_DIR}/overlays/${METALLB_VER}"

}

function npd() {
	NPD_VER=${1:-v0.6.6}
	NPD_URL="https://github.com/kubernetes/node-problem-detector.git"
	NPD_DIR="node-problem-detector"
	get_repo "${NPD_URL}" "${NPD_DIR}/overlays/${NPD_VER}"
	set_repo_version "${NPD_VER}" "${NPD_DIR}/overlays/${NPD_VER}/node-problem-detector"
	kubectl apply -k "${NPD_DIR}/overlays/${NPD_VER}"
}

function miscellaneous() {

	# dashboard
	dashboard

	# EFK
	efk

	#Create an ingress load balancer
	ingres

	#Create a bare metal load balancer.
	#kubectl apply -f 6-metal-lb/metallb.yaml

	#The config map should be properly modified to pick a range that can live
	#on this subnet behind the same gateway (i.e. same L2 domain)
	#kubectl apply -f 6-metal-lb/example-layer2-config.yaml
}

function minimal() {
	cluster_init
	cni
	kata
	metrics
}

function all() {
	minimal
	storage
	monitoring
	miscellaneous
}

function get_repo() {
	local repo="${1}"
	local path="${2}"
	clone_dir=$(basename "${repo}" .git)
	[[ -d "${path}/${clone_dir}" ]] || git -C "${path}" clone "${repo}"

}

function set_repo_version() {
	local ver="${1}"
	local path="${2}"
	pushd "$(pwd)"
	cd "${path}"
	git fetch origin "${ver}"
	git checkout "${ver}"
	popd

}

###
# main
##

declare -A command_handlers
command_handlers[init]=cluster_init
command_handlers[cni]=cni
command_handlers[minimal]=minimal
command_handlers[all]=all
command_handlers[help]=print_usage_exit
command_handlers[storage]=storage
command_handlers[monitoring]=monitoring
command_handlers[metallb]=metallb
command_handlers[npd]=npd

declare -A command_help
command_help[init]="Only inits a cluster using kubeadm"
command_help[cni]="Setup network for running cluster"
command_help[minimal]="init + cni +  kata + metrics"
command_help[all]="minimal + storage + monitoring + miscellaneous"
command_help[help]="show this message"

cd "${SCRIPT_DIR}"

cmd_handler=${command_handlers[${1:-none}]:-unimplemented}
if [ "${cmd_handler}" != "unimplemented" ]; then
	if [ $# -eq 1 ]; then
		"${cmd_handler}"
		exit $?
	fi

	"${cmd_handler}" "$2"

else
	print_usage_exit 1
fi
