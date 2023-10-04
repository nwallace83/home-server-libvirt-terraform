resource "docker_image" "nginx" {
  name = "nginx:latest"
}

resource "docker_container" "nginx" {
  name = "nginx"
  image = docker_image.nginx.name
  restart = "always"

  volumes {
    container_path = "/etc/nginx/nginx.conf"
    host_path = "/etc/nginx.conf"
    read_only = true
  }

  ports {
    ip = "192.168.0.5"
    protocol = "udp"
    internal = 53
    external = 53
  }

  ports {
    ip = "192.168.0.6"
    protocol = "udp"
    internal = 53
    external = 53
  }
}