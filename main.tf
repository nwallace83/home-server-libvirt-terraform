resource "libvirt_pool" "home_server" {
  name = "home-server"
  type = "dir"
  path = "/shared2/VMs"
}

####################################################################################################

resource "libvirt_network" "home-server" {
  name   = "home_server"
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

resource "libvirt_domain" "ubuntu1" {
  name      = "ubuntu1"
  memory    = 2048
  vcpu      = 2
  autostart = false

  disk {
    volume_id = libvirt_volume.ubuntu_base.id
  }

  cloudinit = libvirt_cloudinit_disk.cloud_init.id

  network_interface {
    network_id = libvirt_network.home-server.id
    hostname   = "ubuntu1"
    addresses  = ["192.168.1.5"]
  }

  cpu {
    mode = "host-passthrough"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    websocket   = "-1"
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

}

####################################################################################################

resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu1.qcow2"
  source = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-disk-kvm.img"
  format = "qcow2"
  pool   = libvirt_pool.home_server.name
}

####################################################################################################

resource "libvirt_cloudinit_disk" "cloud_init" {
  name      = "cloud_init.iso"
  user_data = data.template_file.user_data.rendered
  pool      = libvirt_pool.home_server.name
}

data "template_file" "user_data" {
  template = file("${path.module}/cloud_init.cfg")
}
