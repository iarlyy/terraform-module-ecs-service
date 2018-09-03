variable "name" {}
variable "vpc_id" {}
variable "cluster_id" {}
variable "cluster_name" {}
variable "service_iam_role" {}

variable "create_lb" {
  default = false
}

variable "lb_http_listerner_arn" {
  default = ""
}

variable "lb_arn_suffix" {
  default = ""
}

variable "url" {
  default = ""
}

variable "lb_health_check_path" {
  default = "/"
}

variable "task_iam_policies" {
  type    = "list"
  default = []
}

variable "service_autoscaling_enabled" {
  default = false
}

variable "service_autoscaling_adjustment" {
  default = 2
}

variable "service_desired_count" {
  default = 1
}

variable "service_min_count" {
  default = 1
}

variable "service_max_count" {
  default = 1
}

variable "service_min_healthy_percent" {
  default = 0
}

variable "service_deployment_maximum_percent" {
  default = 100
}

variable "service_lb_container_name" {
  default = ""
}

variable "service_lb_container_port" {
  default = 0
}
