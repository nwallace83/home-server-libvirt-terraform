resource "libvirt_domain" "node2" {
  name      = "node2.k8s.local"
  memory    = 7168
  vcpu      = 8
  autostart = true

  disk {
    volume_id = libvirt_volume.node2.id
  }

  filesystem {
    source   = "/kubernetes"
    target   = "kubernetes"
    accessmode = "passthrough"
    readonly = false
  }

  cloudinit = libvirt_cloudinit_disk.disk_node2.id

  network_interface {
    network_id = var.network_id
    mac        = "52:54:00:7e:aa:5b"
    addresses  =[ "192.168.1.11" ]
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

resource "libvirt_volume" "node2" {
  name             = "node2.qcow2"
  pool             = var.pool
  size             = 32212254720
  base_volume_name = var.ubuntu_base_image
  base_volume_pool = var.pool
}

####################################################################################################

resource "libvirt_cloudinit_disk" "disk_node2" {
  name           = "cloud_init_node2.iso"
  user_data      = data.template_file.user_data_node2.rendered
  pool           = var.pool
}

data "template_file" "user_data_node2" {
  template = file("${path.root}/files/user_data.yaml")

  vars = {
    user_password    = var.user_password
    hostname         = "node2"
    bootstrap_script = filebase64("${path.root}/files/bootstrap.sh")
    id_rsa           = filebase64(var.id_rsa)
    argo_ingress     = filebase64("${path.root}/files/argo-ingress.yaml")
    cluster_issuer   = filebase64("${path.root}/files/cluster-issuer.yaml")
    create_cluster   = "false"
    control_plane    = "false"
    seed_host        = "controlplane1"
  }
}
