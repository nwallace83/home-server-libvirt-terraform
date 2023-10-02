#!/bin/bash
CREATE_CLUSTER=$1
CONTROL_PLANE=$2
SEED_HOST=$3
HOSTNAME=$4

echo "~~~~~~~~~~Adding SSH keys customizing environment~~~~~~~~~~"
mkdir -p /home/nate/.ssh
cp /tmp/id_rsa /home/nate/.ssh
echo "alias k='kubectl'" >> /home/nate/.bashrc
echo "alias ssh='ssh -o StrictHostKeychecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'" >> /home/nate/.bashrc
chown -Rf nate:nate /home/nate

mkdir -p /root/.ssh
cp /tmp/id_rsa /root/.ssh
echo "alias k='kubectl'" >> /root/.bashrc
echo "alias ssh='ssh -o StrictHostKeychecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'" >> /root/.bashrc
chown -Rf root:root /root

echo "~~~~~~~~~~Setting up hostname and hosts files~~~~~~~~~~"
hostnamectl set-hostname $HOSTNAME
echo "192.168.0.5 server server.local" >> /etc/hosts
  
echo "~~~~~~~~~~Settings up OS modules~~~~~~~~~~"
tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

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


if [ "$CREATE_CLUSTER" == "true" ]
then
  echo "~~~~~~~~~~SEEDING NEW CLUSTER~~~~~~~~~~"
  kubeadm config images pull
  kubeadm init --control-plane-endpoint=server.local:8443 --pod-network-cidr=10.244.0.0/16

  mkdir -p /home/nate/.kube
  cp /etc/kubernetes/admin.conf /home/nate/.kube/config
  chown -Rf nate:nate /home/nate

  export KUBECONFIG=/etc/kubernetes/admin.conf

  kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml
  kubectl create -f /tmp/custom-resources.yaml

  CLUSTER_STATUS="NotReady"
  while [ "$CLUSTER_STATUS" != "Ready" ]
  do
    echo "Waiting for $HOSTNAME to be ready"
    CLUSTER_STATUS=$(kubectl get nodes | grep $HOSTNAME | awk '{ print $2 }' 2>/dev/null)
    sleep 5
  done

  kubectl create namespace ingress-nginx
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm install --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=32080 \
    --set controller.service.nodePorts.https=32443 \
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
fi

echo "~~~~~~~~~~JOINING CLUSTER~~~~~~~~~~"
CLUSTER_STATUS="NotReady"

while [ "$CLUSTER_STATUS" != "Ready" ]
do
  ssh -o StrictHostKeychecking=no -t $SEED_HOST "kubeadm token list" >/dev/null 2>&1
  if [ $? -eq 0 ]
  then
    sleep 5
    CLUSTER_STATUS=$(ssh -o StrictHostKeychecking=no -t $SEED_HOST "kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes | grep $SEED_HOST | awk '{ print \$2 }'" 2>/dev/null)
    echo "Waiting for $SEED_HOST to be ready"
  else
    echo "Waiting for $SEED_HOST to be ready"
    sleep 20
  fi
done

JOIN_COMMAND=$(ssh -o StrictHostKeychecking=no -t $SEED_HOST "kubeadm token create --print-join-command" 2>/dev/null)
ENDPOINT=$(echo $JOIN_COMMAND | awk '{print $3}')
TOKEN=$(echo $JOIN_COMMAND | awk '{print $5}')
CA_HASH=$(echo $JOIN_COMMAND | awk '{print $7}')

if [ "$CONTROL_PLANE" != "true" ]
then
  kubeadm join $ENDPOINT --token $TOKEN --discovery-token-ca-cert-hash $CA_HASH
else
 mkdir -p /etc/kubernetes/pki/etcd
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/ca.crt
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/ca.key /etc/kubernetes/pki/ca.key
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/sa.pub /etc/kubernetes/pki/sa.pub
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/sa.key /etc/kubernetes/pki/sa.key
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/front-proxy-ca.crt /etc/kubernetes/pki/front-proxy-ca.crt
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/front-proxy-ca.key /etc/kubernetes/pki/front-proxy-ca.key
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/etcd/ca.crt /etc/kubernetes/pki/etcd/ca.crt
  scp -o StrictHostKeychecking=no $SEED_HOST:/etc/kubernetes/pki/etcd/ca.key /etc/kubernetes/pki/etcd/ca.key

  kubeadm config images pull
  kubeadm join $ENDPOINT --token $TOKEN --discovery-token-ca-cert-hash $CA_HASH --control-plane 

  mkdir -p /home/nate/.kube
  cp /etc/kubernetes/admin.conf /home/nate/.kube/config
  chown -Rf nate:nate /home/nate
fi
