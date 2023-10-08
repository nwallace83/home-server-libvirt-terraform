data "docker_registry_image" "haproxy" {
  name = "haproxy:2.8.3-alpine"
}

resource "docker_image" "haproxy" {
  name = data.docker_registry_image.haproxy.name
  pull_triggers = [ data.docker_registry_image.haproxy.sha256_digest ]
}

resource "docker_container" "haproxy-ext" {
  name = "haproxy-ext"
  image = docker_image.haproxy.name
  restart = "always"

  volumes {
    container_path = "/usr/local/etc/haproxy/haproxy.cfg"
    host_path = "/etc/haproxy-ext.cfg"
    read_only = true
  }

  volumes {
    container_path = "/etc/ssl/nwallace.io.pem"
    host_path = "/etc/ssl/nwallace.io.pem"
    read_only = true
  }

  ports {
    ip = "192.168.0.5"
    internal = 80
    external = 8080
  }

  ports {
    ip = "192.168.0.5"
    internal = 443
    external = 8443
  }
}