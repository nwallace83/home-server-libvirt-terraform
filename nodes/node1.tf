resource "libvirt_domain" "node1" {
  name      = "node1.k8s.local"
  memory    = 7168
  vcpu      = 8
  autostart = true

  disk {
    volume_id = libvirt_volume.node1.id
  }

  cloudinit = libvirt_cloudinit_disk.disk_node1.id

  network_interface {
    network_id = var.network_id
    mac        = "52:54:00:7e:aa:4b"
    addresses  =[ "192.168.1.10" ]
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
    target_type = "serial"
    target_port = "0"
  }

  console {
    type        = "pty"
    target_type = "virtio"
    target_port = "1"
  }
}

####################################################################################################

resource "libvirt_volume" "node1" {
  name             = "node1.qcow2"
  pool             = var.pool
  size             = 32212254720
  base_volume_name = var.ubuntu_base_image
  base_volume_pool = var.pool
}

####################################################################################################

resource "libvirt_cloudinit_disk" "disk_node1" {
  name           = "cloud_init_node1.iso"
  user_data      = data.template_file.user_data_node1.rendered
  network_config = data.template_file.network_config_node1.rendered
  pool           = var.pool
}

data "template_file" "user_data_node1" {
  template = file("${path.root}/files/user_data.yaml")

  vars = {
    user_password    = var.user_password
    hostname         = "node1"
    bootstrap_script = filebase64("${path.root}/files/bootstrap.sh")
    id_rsa           = filebase64(var.id_rsa)
    argo_ingress     = filebase64("${path.root}/files/argo-ingress.yaml")
    cluster_issuer   = filebase64("${path.root}/files/cluster-issuer.yaml")
    create_cluster   = "false"
    control_plane    = "false"
    seed_host        = "controlplane1"
  }
}

data "template_file" "network_config_node1" {
  template = file("${path.root}/files/network_config.yaml")
}