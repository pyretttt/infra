module "vcn" {
  source  = "oracle-terraform-modules/vcn/oci"
  version = "~> 3.6"

  compartment_id = var.compartment_id
  region         = var.region

  internet_gateway_route_rules = null
  local_peering_gateways       = null
  nat_gateway_route_rules      = null

  vcn_name      = "k8s-vcn"
  vcn_dns_label = "k8svcn"
  vcn_cidrs     = ["10.0.0.0/16"]

  create_internet_gateway = true
  create_nat_gateway      = true
  create_service_gateway  = true
}

# Public subnet (10.0.0.0/24): OKE API endpoint + NLB.
# This SL protects those control-plane / edge VNICs, not the worker nodes.
resource "oci_core_security_list" "public_subnet_sl" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id

  display_name = "k8s-public-subnet-sl"

  # API endpoint / NLB must reach workers (kubelet, NodePorts, health checks), OCI
  # services, and the internet. Covers NLB→31600/31601 and health checks→10256.
  egress_security_rules {
    stateless        = false
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    description      = "Kubernetes API endpoint and NLB to worker nodes, OCI services and the internet"
  }

  # Workers call the apiserver on 6443 (auth webhooks, kubectl proxy, CNI, etc.).
  ingress_security_rules {
    stateless   = false
    source      = "10.0.1.0/24"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    description = "Kubernetes worker to Kubernetes API endpoint communication"
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # OKE control-plane channel from workers (kubelet / node agent) to the API endpoint.
  ingress_security_rules {
    stateless   = false
    source      = "10.0.1.0/24"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    description = "Kubernetes worker to control plane communication"
    tcp_options {
      min = 12250
      max = 12250
    }
  }

  # Public kubectl / CI access to the cluster API. Also used by in-cluster components
  # that talk to the apiserver via its public IP.
  ingress_security_rules {
    stateless   = false
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    description = "External access to the public Kubernetes API endpoint (kubectl)"
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # ICMP fragmentation-needed (type 3 code 4) so Path MTU Discovery works from workers
  # toward the API endpoint / NLB path.
  ingress_security_rules {
    stateless   = false
    source      = "10.0.1.0/24"
    source_type = "CIDR_BLOCK"
    protocol    = "1"
    description = "Path discovery"
    icmp_options {
      type = 3
      code = 4
    }
  }

  # Internet → NLB listener (HTTP).
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false
    description = "Internet to NLB HTTP listener"
    tcp_options {
      max = 80
      min = 80
    }
  }

  # Internet → NLB listener (HTTPS, TLS terminated at the in-cluster ingress).
  ingress_security_rules {
    protocol    = "6"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false
    description = "Internet to NLB HTTPS listener"
    tcp_options {
      max = 443
      min = 443
    }
  }

  ingress_security_rules {
    protocol    = "17"
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    stateless   = false
    description = "Internet to NLB WireGuard listener"
    udp_options {
      max = 51820
      min = 51820
    }
  }
}

# Private subnet (10.0.1.0/24): worker nodes (and their pods via node networking).
resource "oci_core_security_list" "private_subnet_sl" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id

  display_name = "k8s-private-subnet-sl"

  # Nodes need outbound to the API endpoint, OCI services (via SGW/NAT), image registries,
  # and general internet for pulls / package updates.
  egress_security_rules {
    stateless        = false
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    description      = "Worker nodes to Kubernetes API endpoint, OCI services and the internet"
  }

  # East-west: pod↔pod and node↔node inside the worker subnet. Also allows OCI Bastion
  # managed sessions that land on worker VNICs in this subnet.
  ingress_security_rules {
    stateless   = false
    source      = "10.0.1.0/24"
    source_type = "CIDR_BLOCK"
    protocol    = "all"
    description = "Pod to pod traffic between worker nodes, and OCI Bastion sessions"
  }

  # Traffic from the public subnet toward workers. Broad TCP allow because both the API
  # endpoint (kubelet 10250) and the NLB (ingress NodePorts 31600/31601 + health 10256)
  # source from 10.0.0.0/24.
  ingress_security_rules {
    stateless   = false
    source      = "10.0.0.0/24"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    description = "Kubernetes API endpoint and network load balancer to worker nodes"
  }

  ingress_security_rules {
    stateless   = false
    source      = "10.0.0.0/24"
    source_type = "CIDR_BLOCK"
    protocol    = "17"
    description = "Network load balancer WireGuard listener to worker nodes"
  }

  # ICMP fragmentation-needed from anywhere so PMTUD can correct MTU for node traffic
  # (including responses toward the internet via NAT).
  ingress_security_rules {
    stateless   = false
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "1"
    description = "Path discovery"
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "vcn_private_subnet" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id
  cidr_block     = "10.0.1.0/24"

  route_table_id             = module.vcn.nat_route_id
  security_list_ids          = [oci_core_security_list.private_subnet_sl.id]
  display_name               = "k8s-private-subnet"
  prohibit_public_ip_on_vnic = true
}

resource "oci_core_subnet" "vcn_public_subnet" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id
  cidr_block     = "10.0.0.0/24"

  route_table_id    = module.vcn.ig_route_id
  security_list_ids = [oci_core_security_list.public_subnet_sl.id]
  display_name      = "k8s-public-subnet"
}

# L4 NLB in front of a fixed ingress NodePort Service:
#   Internet → NLB :80/:443 → worker NodePort 31600/31601 → ingress controller
# Pin those nodePorts in your kustomize Service; do not let Kubernetes allocate others.
data "oci_containerengine_node_pool" "k8s_node_pool" {
  count = var.arm_pool_count

  node_pool_id = oci_containerengine_node_pool.k8s_node_pool[count.index].id
  depends_on   = [oci_containerengine_node_pool.k8s_node_pool]
}

locals {
  ingress_http_node_port  = 31600
  ingress_https_node_port = 31601
  ingress_wg_node_port    = 31602
  # Must be known at plan time — do not derive count from data-source node lists.
  worker_count = var.arm_pool_count * var.arm_pool_size
  # Flat worker list for NLB backends. Avoid filtering by state here: an ACTIVE-only
  # filter makes length unknown at plan and can under-count mid-rollout.
  worker_nodes = flatten([
    for pool in data.oci_containerengine_node_pool.k8s_node_pool : pool.nodes
  ])
}

resource "oci_network_load_balancer_network_load_balancer" "nlb" {
  compartment_id                 = var.compartment_id
  display_name                   = "k8s-nlb"
  subnet_id                      = oci_core_subnet.vcn_public_subnet.id
  is_private                     = false
  is_preserve_source_destination = false
}

resource "oci_network_load_balancer_backend_set" "nlb_http_backend_set" {
  health_checker {
    protocol = "TCP"
    port     = 10256 # kube-proxy healthz (node up), not ingress readiness
  }
  name                     = "k8s-http-backend-set"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false
}

resource "oci_network_load_balancer_backend_set" "nlb_https_backend_set" {
  health_checker {
    protocol = "TCP"
    port     = 10256
  }
  name                     = "k8s-https-backend-set"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false
}
resource "oci_network_load_balancer_backend_set" "nlb_wg_backend_set" {
  health_checker {
    protocol = "TCP"
    port     = 10256
  }
  name                     = "k8s-wg-backend-set"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  policy                   = "FIVE_TUPLE"
  is_preserve_source       = false
}

resource "oci_network_load_balancer_backend" "nlb_http_backend" {
  depends_on = [oci_containerengine_node_pool.k8s_node_pool]

  count                    = local.worker_count
  backend_set_name         = oci_network_load_balancer_backend_set.nlb_http_backend_set.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  port                     = local.ingress_http_node_port
  target_id                = local.worker_nodes[count.index].id
}
resource "oci_network_load_balancer_backend" "nlb_https_backend" {
  depends_on = [oci_containerengine_node_pool.k8s_node_pool]

  count                    = local.worker_count
  backend_set_name         = oci_network_load_balancer_backend_set.nlb_https_backend_set.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  port                     = local.ingress_https_node_port
  target_id                = local.worker_nodes[count.index].id
}
resource "oci_network_load_balancer_backend" "nlb_wg_backend" {
  depends_on = [oci_containerengine_node_pool.k8s_node_pool]

  count                    = local.worker_count
  backend_set_name         = oci_network_load_balancer_backend_set.nlb_wg_backend_set.name
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  port                     = local.ingress_wg_node_port
  target_id                = local.worker_nodes[count.index].id
}

resource "oci_network_load_balancer_listener" "nlb_http_listener" {
  default_backend_set_name = oci_network_load_balancer_backend_set.nlb_http_backend_set.name
  name                     = "k8s-nlb-http-listener"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  port                     = 80
  protocol                 = "TCP"
}

resource "oci_network_load_balancer_listener" "nlb_https_listener" {
  default_backend_set_name = oci_network_load_balancer_backend_set.nlb_https_backend_set.name
  name                     = "k8s-nlb-https-listener"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  port                     = 443
  protocol                 = "TCP"
}
resource "oci_network_load_balancer_listener" "nlb_wg_listener" {
  default_backend_set_name = oci_network_load_balancer_backend_set.nlb_wg_backend_set.name
  name                     = "k8s-nlb-wg-listener"
  network_load_balancer_id = oci_network_load_balancer_network_load_balancer.nlb.id
  port                     = 51820
  protocol                 = "UDP"
}

locals {
  cfg = {
    http_port = local.ingress_http_node_port
    https_port = local.ingress_https_node_port
    wg_port = local.ingress_wg_node_port
  }
}

resource "null_resource" "ingress_node_port" {
  triggers = {
    content_sha = sha256(templatefile("ingress-node-port.yaml.tftpl", {
      cfg = local.cfg
    }))
  }

  provisioner "local-exec" {
    working_dir = path.module
    command     = <<-EOT
      set -eu

      cat > ../manifests/provisioned/ingress/ingress-node-port.yaml <<'EOF'
${templatefile("ingress-node-port.yaml.tftpl", {
  cfg = local.cfg
})}
EOF
      chmod 0640 ../manifests/provisioned/ingress/ingress-node-port.yaml
    EOT
  }
}
