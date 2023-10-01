resource "docker_image" "haproxy" {
  name = "haproxy:latest"
}

resource "docker_container" "haproxy" {
  name = "haproxy"
  image = docker_image.haproxy.name
  restart = "always"

  volumes {
    container_path = "/usr/local/etc/haproxy/haproxy.cfg"
    host_path = "/etc/haproxy.cfg"
    read_only = true
  }

  ports {
    internal = 8443
    external = 8443
  }

  ports {
    internal = 32080
    external = 32080
  }
  
  ports {
    internal = 32443
    external = 32443
  }
}