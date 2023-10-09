#!/bin/bash
CREATE_CLUSTER=$1
CONTROL_PLANE=$2
SEED_HOST=$3
HOSTNAME=$4
API_ENDPOINT="server.local:6443"
POD_CIDR="10.244.0.0/16"

echo "~~~~~~~~~~Adding SSH keys customizing environment~~~~~~~~~~"
mkdir -p /home/nate/.ssh
cp /tmp/id_rsa /home/nate/.ssh
echo "alias k='kubectl'" >>/home/nate/.bashrc
echo "alias ssh='ssh -o StrictHostKeychecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'" >>/home/nate/.bashrc
echo "export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock" >>/home/nate/.bashrc
chown -Rf nate:nate /home/nate

mkdir -p /root/.ssh
cp /tmp/id_rsa /root/.ssh
echo "alias k='kubectl'" >>/root/.bashrc
echo "alias ssh='ssh -o StrictHostKeychecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'" >>/root/.bashrc
echo "export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock" >>/root/.bashrc
chown -Rf root:root /root

echo "kubernetes /kubernetes 9p  trans=virtio,version=9p2000.L,posixacl,msize=5000000,cache=mmap,rw  0 0" >>/etc/fstab
mkdir /kubernetes
mount /kubernetes

echo "~~~~~~~~~~Setting up hostname and hosts files~~~~~~~~~~"
hostnamectl set-hostname $HOSTNAME
echo "192.168.0.5 server server.local" >>/etc/hosts

echo "~~~~~~~~~~Settings up OS modules~~~~~~~~~~"
tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF

tee /etc/modules-load.d/libvirt.conf <<EOF
 loop
 virtio
 9p
 9pnet
 9pnet_virtio
EOF

modprobe overlay
modprobe br_netfilter
modprobe loop
modprobe virtio
modprobe 9p
modprobe 9pnet
modprobe 9pnet_virtio

tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system

echo "~~~~~~~~~~Adding repositories and downloading required software~~~~~~~~~~"
apt install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates nfs-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
apt update
apt install -y containerd.io kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

if [ "$CREATE_CLUSTER" == "true" ]; then
  echo "~~~~~~~~~~SEEDING NEW CLUSTER~~~~~~~~~~"
  kubeadm config images pull
  kubeadm init --control-plane-endpoint=$API_ENDPOINT --pod-network-cidr=$POD_CIDR

  mkdir -p /home/nate/.kube
  cp /etc/kubernetes/admin.conf /home/nate/.kube/config
  chown -Rf nate:nate /home/nate

  export KUBECONFIG=/etc/kubernetes/admin.conf

  kubectl create ns kube-flannel
  kubectl label --overwrite ns kube-flannel pod-security.kubernetes.io/enforce=privileged

  helm repo add flannel https://flannel-io.github.io/flannel/
  helm install flannel --set podCidr="10.244.0.0/16" --namespace kube-flannel flannel/flannel

  CLUSTER_STATUS="NotReady"
  while [ "$CLUSTER_STATUS" != "Ready" ]; do
    echo "Waiting for $HOSTNAME to be ready"
    CLUSTER_STATUS=$(kubectl get nodes | grep $HOSTNAME | awk '{ print $2 }' 2>/dev/null)
    sleep 5
  done

  echo "~~~~~~~~~~INSTALLING ETCD CLIENT~~~~~~~~~~"
  RELEASE=$(curl -s https://api.github.com/repos/etcd-io/etcd/releases/latest|grep tag_name | cut -d '"' -f 4)
  wget https://github.com/etcd-io/etcd/releases/download/${RELEASE}/etcd-${RELEASE}-linux-amd64.tar.gz
  tar xvf etcd-${RELEASE}-linux-amd64.tar.gz
  mv etcd-${RELEASE}-linux-amd64/etcd /usr/local/bin
  mv etcd-${RELEASE}-linux-amd64/etcdctl /usr/local/bin
  mv etcd-${RELEASE}-linux-amd64/etcdutl /usr/local/bin
  rm etcd-${RELEASE}-linux-amd64.tar.gz
  rm -Rf etcd-${RELEASE}-linux-amd64
  echo "export ETCDCTL_API=3" >> /root/.bashrc
  ETCDCTL_CMD="etcdctl --endpoints=https://controlplane1:2379,https://controlplane2:2379,https://controlplane3:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"
  echo "alias etcdctl='$ETCDCTL_CMD'" >> /root/.bashrc

  kubectl create namespace ingress-nginx
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm install --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30080 \
    --set controller.service.nodePorts.https=30443 \
    --set controller.allowSnippetAnnotations=true \
    ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx

  kubectl create namespace argo-cd
  helm repo add argo-cd https://argoproj.github.io/argo-helm
  helm install --set configs.params."server\.insecure"=true argo-cd argo-cd/argo-cd -n argo-cd

  kubectl create namespace cert-manager
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.crds.yaml
  helm repo add cert-manager https://charts.jetstack.io
  helm install cert-manager cert-manager/cert-manager -n cert-manager

  sleep 60
  kubectl apply -f /tmp/cluster-issuer.yaml
  kubectl apply -f /tmp/argo-ingress.yaml -n argo-cd
  echo "ArgoCD password: $(kubectl -n argo-cd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"

  exit 0
  reboot
fi

echo "~~~~~~~~~~JOINING CLUSTER~~~~~~~~~~"
CLUSTER_STATUS="NotReady"

while [ "$CLUSTER_STATUS" != "Ready" ]; do
  ssh -o StrictHostKeychecking=no -o UserKnownHostsFile=/dev/null -t $SEED_HOST "kubeadm token list" >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    sleep 5
    CLUSTER_STATUS=$(ssh -o StrictHostKeychecking=no -o UserKnownHostsFile=/dev/null -t $SEED_HOST "kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes | grep $SEED_HOST | awk '{ print \$2 }'" 2>/dev/null)
    echo "Waiting for $SEED_HOST to be ready"
  else
    echo "Waiting for $SEED_HOST to be ready"
    sleep 20
  fi
done

JOIN_COMMAND=$(ssh -o StrictHostKeychecking=no -o UserKnownHostsFile=/dev/null -t $SEED_HOST "kubeadm token create --print-join-command" 2>/dev/null)
ENDPOINT=$(echo $JOIN_COMMAND | awk '{print $3}')
TOKEN=$(echo $JOIN_COMMAND | awk '{print $5}')
CA_HASH=$(echo $JOIN_COMMAND | awk '{print $7}')

if [ "$CONTROL_PLANE" != "true" ]; then
  echo "~~~~~~~~~~JOINING AS WORKER NODE~~~~~~~~~~"
  kubeadm join $ENDPOINT --token $TOKEN --discovery-token-ca-cert-hash $CA_HASH
  echo "~~~~~~~~~~REBOOTING~~~~~~~~~~"
  reboot
else
  echo "~~~~~~~~~~JOINING AS CONTROLPLANE~~~~~~~~~~"
  echo "~~~~~~~~~~COPYING CERTIFICATES FROM $SEED_HOST~~~~~~~~~~"
  mkdir -p /etc/kubernetes/pki/etcd
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/ca.crt
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/ca.key /etc/kubernetes/pki/ca.key
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/sa.pub /etc/kubernetes/pki/sa.pub
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/sa.key /etc/kubernetes/pki/sa.key
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/front-proxy-ca.crt /etc/kubernetes/pki/front-proxy-ca.crt
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/front-proxy-ca.key /etc/kubernetes/pki/front-proxy-ca.key
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/etcd/ca.crt /etc/kubernetes/pki/etcd/ca.crt
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/etcd/ca.key /etc/kubernetes/pki/etcd/ca.key

  echo "~~~~~~~~~~INSTALLING ETCD CLIENT~~~~~~~~~~"
  RELEASE=$(curl -s https://api.github.com/repos/etcd-io/etcd/releases/latest|grep tag_name | cut -d '"' -f 4)
  wget https://github.com/etcd-io/etcd/releases/download/${RELEASE}/etcd-${RELEASE}-linux-amd64.tar.gz
  tar xvf etcd-${RELEASE}-linux-amd64.tar.gz
  mv etcd-${RELEASE}-linux-amd64/etcd /usr/local/bin
  mv etcd-${RELEASE}-linux-amd64/etcdctl /usr/local/bin
  mv etcd-${RELEASE}-linux-amd64/etcdutl /usr/local/bin
  rm etcd-${RELEASE}-linux-amd64.tar.gz
  rm -Rf etcd-${RELEASE}-linux-amd64
  echo "export ETCDCTL_API=3" >> /root/.bashrc
  ETCDCTL_CMD="etcdctl --endpoints=https://controlplane1:2379,https://controlplane2:2379,https://controlplane3:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key"
  echo "alias etcdctl='$ETCDCTL_CMD'" >> /root/.bashrc

  echo "~~~~~~~~~~CHECKING ETCD MEMBERSHIP~~~~~~~~~~"
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/etcd/server.crt /tmp/server.crt
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/etcd/server.key /tmp/server.key
  ETCD_FLAGS="--endpoints=https://$SEED_HOST:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/tmp/server.crt --key=/tmp/server.key"
  MEMBER_EXISTS=$(etcdctl $ETCD_FLAGS member list | grep $HOSTNAME | wc -l)
  if [ $MEMBER_EXISTS -eq 1 ]
  then
    echo "Member already exists in etcd, attempting to remove"
    MEMBER_ID=$(etcdctl $ETCD_FLAGS member list | grep $HOSTNAME | awk '{print $1}' | sed 's/,//g')
    etcdctl $ETCD_FLAGS member remove $MEMBER_ID
  fi

  rm /tmp/server.crt
  rm /tmp/server.key

  echo "~~~~~~~~~~JOINING CLUSTER~~~~~~~~~~"
  kubeadm config images pull
  kubeadm join $ENDPOINT --token $TOKEN --discovery-token-ca-cert-hash $CA_HASH --control-plane

  mkdir -p /home/nate/.kube
  cp /etc/kubernetes/admin.conf /home/nate/.kube/config
  chown -Rf nate:nate /home/nate

  mkdir -p /root/.kube
  cp /etc/kubernetes/admin.conf /root/.kube/config
  chown -Rf root:root /root

  echo "~~~~~~~~~~REBOOTING~~~~~~~~~~"
  reboot
fi
