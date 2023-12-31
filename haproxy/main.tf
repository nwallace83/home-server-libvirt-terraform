data "docker_registry_image" "haproxy" {
  name = "haproxy:2.8.3-alpine"
}

resource "docker_image" "haproxy" {
  name = data.docker_registry_image.haproxy.name
  pull_triggers = [ data.docker_registry_image.haproxy.sha256_digest ]
}

resource "docker_container" "haproxy" {
  name = "haproxy"
  image = docker_image.haproxy.name
  restart = "always"

  env = [ "PUID=1000","GUID=1000" ]

  volumes {
    container_path = "/usr/local/etc/haproxy/haproxy.cfg"
    host_path = "/etc/haproxy.cfg"
    read_only = true
  }

  ports {
    ip = "192.168.0.5"
    internal = 6443
    external = 6443
  }

  ports {
    ip = "192.168.0.5"
    internal = 80
    external = 80
  }
  
  ports {
    ip = "192.168.0.5"
    internal = 443
    external = 443
  }

  ports {
    ip = "192.168.0.5"
    internal = 32400
    external = 32400
  }
}