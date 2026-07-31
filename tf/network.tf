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

resource "oci_core_security_list" "public_subnet_sl" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id

  display_name = "k8s-public-subnet-sl"

  egress_security_rules {
    stateless        = false
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    description      = "Kubernetes API endpoint to worker nodes, OCI services and the internet"
  }

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

  ingress_security_rules {
    stateless   = false
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    description = "External access to the public Kubernetes API endpoint (kubectl, cilium k8sServiceHost)"
    tcp_options {
      min = 6443
      max = 6443
    }
  }

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
}

resource "oci_core_security_list" "private_subnet_sl" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id

  display_name = "k8s-private-subnet-sl"

  egress_security_rules {
    stateless        = false
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    description      = "Worker nodes to Kubernetes API endpoint, OCI services and the internet"
  }

  ingress_security_rules {
    stateless   = false
    source      = "10.0.1.0/24"
    source_type = "CIDR_BLOCK"
    protocol    = "all"
    description = "Pod to pod traffic between worker nodes, and OCI Bastion sessions"
  }

  # The NLB shares the public subnet with the API endpoint, so this single rule covers
  # both control plane to kubelet (10250) and NLB to node ports (30000-32767, 10256).
  ingress_security_rules {
    stateless   = false
    source      = "10.0.0.0/24"
    source_type = "CIDR_BLOCK"
    protocol    = "6"
    description = "Kubernetes API endpoint and network load balancer to worker nodes"
  }

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

resource "oci_core_network_security_group" "nginx_ingress_network_security_group" {
  compartment_id = var.compartment_id
  vcn_id         = module.vcn.vcn_id
}

resource "oci_core_network_security_group_security_rule" "nginx_ingress_network_security_group_security_rule_443" {
  network_security_group_id = oci_core_network_security_group.nginx_ingress_network_security_group.id
  description               = "nginx-ingress"
  direction                 = "INGRESS"
  protocol                  = 6

  source      = "0.0.0.0/0"
  source_type = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      max = 443
      min = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nginx_ingress_network_security_group_security_rule_80" {
  network_security_group_id = oci_core_network_security_group.nginx_ingress_network_security_group.id
  description               = "nginx-ingress"
  direction                 = "INGRESS"
  protocol                  = 6

  source      = "0.0.0.0/0"
  source_type = "CIDR_BLOCK"
  tcp_options {
    destination_port_range {
      max = 80
      min = 80
    }
  }
}

resource "null_resource" "gateway_nlb_patch" {
  triggers = {
    content_sha = sha256(templatefile("gateway-nlb-patch.yaml.tftpl", {
      nsg_ocid = oci_core_network_security_group.nginx_ingress_network_security_group.id
    }))
  }

  provisioner "local-exec" {
    working_dir = path.module
    command = <<-EOT
      set -eu

      if [ -e ../flux-modules/kube-system/gateway-nlb-patch.yaml ]; then
        echo "../flux-modules/kube-system/gateway-nlb-patch.yaml already exists, leaving it unchanged"
        exit 0
      fi

      cat > ../flux-modules/kube-system/gateway-nlb-patch.yaml <<'EOF'
${templatefile("gateway-nlb-patch.yaml.tftpl", {
    nsg_ocid = oci_core_network_security_group.nginx_ingress_network_security_group.id
})}
EOF
      chmod 0640 ../flux-modules/kube-system/gateway-nlb-patch.yaml
    EOT
}
}
