output "k8s-cluster-id" {
  value = oci_containerengine_cluster.k8s_cluster.id
}

output "arm-instance-volume-ocids" {
  value = oci_core_volume.arm_instance_volume[*].id
}

output "load_balancer_public_ips" {
  value = [
    for ip in oci_network_load_balancer_network_load_balancer.nlb.ip_addresses : ip.ip_address if ip.is_public
  ]
}

output "load_balancer_public_ip" {
  value = one([
    for ip in oci_network_load_balancer_network_load_balancer.nlb.ip_addresses : ip.ip_address if ip.is_public
  ])
}

output "ingress_http_node_port" {
  value = local.ingress_http_node_port
}

output "ingress_https_node_port" {
  value = local.ingress_https_node_port
}
