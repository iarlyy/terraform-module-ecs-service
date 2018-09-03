data "aws_caller_identity" "aws" {}

resource "aws_lb_target_group" "lb_tg" {
  count                = "${var.create_lb ? 1 : 0}"
  name_prefix          = "lb-"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = "${var.vpc_id}"
  deregistration_delay = "60"

  health_check {
    timeout             = "10"
    healthy_threshold   = "3"
    unhealthy_threshold = "3"
    interval            = "30"
    path                = "${var.lb_health_check_path}"
    protocol            = "HTTP"
    matcher             = "200"
  }

  tags {
    Terraform = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "host_based_routing" {
  count        = "${var.create_lb ? 1 : 0}"
  listener_arn = "${var.lb_http_listerner_arn}"
  priority     = 99

  action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.lb_tg.arn}"
  }

  condition {
    field  = "host-header"
    values = ["${var.url}"]
  }

  depends_on = ["aws_lb_target_group.lb_tg"]
}

# task definition
resource "aws_iam_role" "ecs_task" {
  name        = "ECSTask-${var.name}"
  description = "Managed by Terraform"
  path        = "/ecs/"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": ["ecs-tasks.amazonaws.com"]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "ecs_task" {
  count      = "${length(var.task_iam_policies)}"
  role       = "${aws_iam_role.ecs_task.name}"
  policy_arn = "${element(var.task_iam_policies, count.index)}"
}

data "template_file" "task_definition" {
  template = "${file("${path.module}/task_definition.template")}"

  vars {
    ecs_cluster_name = "${var.cluster_name}"
  }
}

resource "aws_ecs_task_definition" "task" {
  family                = "${var.name}"
  container_definitions = "${data.template_file.task_definition.rendered}"
  task_role_arn         = "${aws_iam_role.ecs_task.arn}"
  network_mode          = "bridge"

  lifecycle {
    ignore_changes = ["container_definitions"]
  }
}

data "aws_ecs_task_definition" "task" {
  task_definition = "${aws_ecs_task_definition.task.id}"
}

# web-tier
resource "aws_ecs_service" "service_without_lb" {
  count                              = "${var.create_lb ? 0 : 1}"
  name                               = "${var.name}"
  cluster                            = "${var.cluster_id}"
  task_definition                    = "${aws_ecs_task_definition.task.family}:${max("${aws_ecs_task_definition.task.revision}", "${data.aws_ecs_task_definition.task.revision}")}"
  deployment_maximum_percent         = "${var.service_deployment_maximum_percent}"
  deployment_minimum_healthy_percent = "${var.service_min_healthy_percent}"
  desired_count                      = "${var.service_desired_count}"

  ordered_placement_strategy {
    type  = "binpack"
    field = "memory"
  }
}

# worker-tier
resource "aws_ecs_service" "service_with_lb" {
  count                              = "${var.create_lb ? 1 : 0}"
  name                               = "${var.name}"
  cluster                            = "${var.cluster_id}"
  task_definition                    = "${aws_ecs_task_definition.task.family}:${max("${aws_ecs_task_definition.task.revision}", "${data.aws_ecs_task_definition.task.revision}")}"
  deployment_maximum_percent         = "${var.service_deployment_maximum_percent}"
  deployment_minimum_healthy_percent = "${var.service_min_healthy_percent}"
  desired_count                      = "${var.service_desired_count}"
  iam_role                           = "${var.service_iam_role}"

  ordered_placement_strategy {
    type  = "binpack"
    field = "memory"
  }

  load_balancer {
    target_group_arn = "${aws_lb_target_group.lb_tg.arn}"
    container_name   = "${var.service_lb_container_name}"
    container_port   = "${var.service_lb_container_port}"
  }

  lifecycle {
    ignore_changes = ["desired_count"]
  }
}

# App autoscaling
resource "aws_appautoscaling_target" "scaling_target" {
  count              = "${var.service_autoscaling_enabled ? 1 : 0}"
  min_capacity       = "${var.service_min_count}"
  max_capacity       = "${var.service_max_count}"
  resource_id        = "service/${var.cluster_name}/${var.name}"
  role_arn           = "arn:aws:iam::${data.aws_caller_identity.aws.account_id}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_ECSService"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = ["aws_ecs_service.service_with_lb"]
}

resource "aws_appautoscaling_policy" "scale_up" {
  count              = "${var.service_autoscaling_enabled ? 1 : 0}"
  name               = "SCALE-UP-${aws_appautoscaling_target.scaling_target.id}"
  resource_id        = "service/${var.cluster_name}/${var.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0.0
      scaling_adjustment          = "${var.service_autoscaling_adjustment}"
    }
  }

  depends_on = ["aws_appautoscaling_target.scaling_target"]
}

resource "aws_appautoscaling_policy" "scale_down" {
  count              = "${var.service_autoscaling_enabled ? 1 : 0}"
  name               = "SCALE-DOWN-${aws_appautoscaling_target.scaling_target.id}"
  resource_id        = "service/${var.cluster_name}/${var.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = 0.0
      scaling_adjustment          = -1
    }
  }

  depends_on = ["aws_appautoscaling_target.scaling_target"]
}

# Cloudwatch
resource "aws_cloudwatch_metric_alarm" "ecs_service_scaling_alarm" {
  count               = "${var.service_autoscaling_enabled ? 1 : 0}"
  alarm_name          = "ECS_Service-${var.name}_ReqsPerTask"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "RequestCountPerTarget"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Sum"
  threshold           = "3000"                                          # 50reqs * 60s
  alarm_description   = "Managed by Terraform"
  treat_missing_data  = "notBreaching"
  alarm_actions       = ["${aws_appautoscaling_policy.scale_up.arn}"]
  ok_actions          = ["${aws_appautoscaling_policy.scale_down.arn}"]

  dimensions {
    LoadBalancer = "${var.lb_arn_suffix}"
    TargetGroup  = "${aws_lb_target_group.lb_tg.arn_suffix}"
  }

  depends_on = ["aws_appautoscaling_target.scaling_target", "aws_appautoscaling_policy.scale_up", "aws_appautoscaling_policy.scale_down"]
}
