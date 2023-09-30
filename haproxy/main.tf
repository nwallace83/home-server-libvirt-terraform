resource "docker_image" "haproxy" {
  name = "haproxy:latest"
}

resource "docker_container" "haproxy" {
  name = "haproxy"
  image = docker_image.haproxy.name
  restart = "unless-stopped"

  volumes {
    container_path = "/usr/local/etc/haproxy/haproxy.cfg"
    host_path = "/etc/haproxy.cfg"
    read_only = true
  }

  ports {
    internal = 8443
    external = 8443
  }
}