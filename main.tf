resource "libvirt_pool" "home_server" {
  name = "home-server"
  type = "dir"
  path = "/shared2/VMs"
}

####################################################################################################

resource "libvirt_network" "home-server" {
  name   = "home-server"
  mode   = "nat"
  domain = "k8s.local"

  addresses = ["192.168.1.0/24"]
  bridge    = "virbr1"
  autostart = true

  dns {
    enabled    = true
    local_only = true
  }

  dhcp {
    enabled = true
  }
}

####################################################################################################

resource "libvirt_volume" "ubuntu_base" {
  name   = "jammy-server-cloudimg-amd64.img"
  source = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  pool   = libvirt_pool.home_server.name
}

####################################################################################################

module "nodes" {
  source = "./nodes"
  
  network_id = libvirt_network.home-server.id
  id_rsa = var.id_rsa
  user_password = var.user_password
  pool = libvirt_pool.home_server.name
  ubuntu_base_image = libvirt_volume.ubuntu_base.name
  create_cluster = var.create_cluster
}

####################################################################################################

module "haproxy" {
  source = "./haproxy"
}

####################################################################################################

module "nginx" {
  source = "./nginx"
}

