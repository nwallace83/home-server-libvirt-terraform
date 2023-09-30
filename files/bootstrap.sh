#!/bin/bash -x

mkdir -p /home/nate/.ssh
cp /tmp/id_rsa /home/nate/.ssh
chown -Rf nate:nate /home/nate

mkdir -p /root/.ssh
cp /tmp/id_rsa /root/.ssh
chown -Rf root:root /root

hostnamectl set-hostname $2
  
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
apt install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates
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


if [ "$1" == "true" ]
then
  echo "~~~~~~~~~~SEEDING NEW CLUSTER~~~~~~~~~~"
  kubeadm config images pull
  kubeadm init --control-plane-endpoint=controlplane1.k8s.local --pod-network-cidr=10.244.0.0/16
  mkdir -p /home/nate/.kube
  cp /etc/kubernetes/admin.conf /home/nate/.kube/config
  chown -Rf nate:nate /home/nate
  kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml
  kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f /tmp/custom-resources.yaml
else
  echo echo "~~~~~~~~~~JOINING CLUSTER~~~~~~~~~~"
  CLUSTER_STATUS="NotReady"

  while [ "$CLUSTER_STATUS" != "Ready" ]
  do
    ssh -o StrictHostKeychecking=no -t controlplane1 "kubeadm token list"
    if [ $? -eq 0 ]
    then
      CLUSTER_STATUS=$(ssh -o StrictHostKeychecking=no -t controlplane1 "kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes | grep controlplane1 | awk '{ print \$2 }'")
    else
      sleep 20
    fi
  done

  JOIN_COMMAND=$(ssh -o StrictHostKeychecking=no -t controlplane1 "kubeadm token create --print-join-command")
  ENDPOINT=$(echo $JOIN_COMMAND | awk '{print $3}')
  TOKEN=$(echo $JOIN_COMMAND | awk '{print $5}')
  CA_HASH=$(echo $JOIN_COMMAND | awk '{print $7}')

  kubeadm join $ENDPOINT --token $TOKEN --discovery-token-ca-cert-hash $CA_HASH
fi