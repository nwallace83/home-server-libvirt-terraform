data "docker_registry_image" "nginx" {
  name = "nginx:1.25.2-alpine"
}

resource "docker_image" "nginx" {
  name = data.docker_registry_image.nginx.name
  pull_triggers = [ data.docker_registry_image.nginx.sha256_digest ]
}

resource "docker_container" "nginx" {
  name = "nginx"
  image = docker_image.nginx.name
  restart = "always"

  env = [ "PUID=1000","GUID=1000" ]

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
}