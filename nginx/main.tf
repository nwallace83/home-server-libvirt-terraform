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
    internal = 30053
    external = 30053
  }
}