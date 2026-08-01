resource "oci_containerengine_cluster" "k8s_cluster" {
  compartment_id     = var.compartment_id
  kubernetes_version = var.k8s_version
  name               = "k8s-cluster"
  vcn_id             = module.vcn.vcn_id

  endpoint_config {
    is_public_ip_enabled = true # allows public access to the cluster
    subnet_id            = oci_core_subnet.vcn_public_subnet.id # public subnet
  }

  options {
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }
    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
    service_lb_subnet_ids = [oci_core_subnet.vcn_public_subnet.id]
  }
}

data "oci_containerengine_cluster_kube_config" "k8s_cluster_kube_config" {
  #Required
  cluster_id = oci_containerengine_cluster.k8s_cluster.id
}

resource "null_resource" "kube_config" {
  depends_on = [oci_containerengine_node_pool.k8s_node_pool]

  triggers = {
    content_sha = sha256(data.oci_containerengine_cluster_kube_config.k8s_cluster_kube_config.content)
  }

  provisioner "local-exec" {
    working_dir = path.module
    command     = <<-EOT
      set -eu

      if [ -e .kube.config ]; then
        echo ".kube.config already exists, leaving it unchanged"
        exit 0
      fi

      cat > .kube.config <<'EOF'
${data.oci_containerengine_cluster_kube_config.k8s_cluster_kube_config.content}
EOF
      chmod 0400 .kube.config
    EOT
  }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

resource "oci_containerengine_node_pool" "k8s_node_pool" {
  count              = var.arm_pool_count
  cluster_id         = oci_containerengine_cluster.k8s_cluster.id
  compartment_id     = var.compartment_id
  kubernetes_version = var.k8s_version
  name               = "k8s-node-pool-${count.index}"

  depends_on = [oci_core_volume.arm_instance_volume, oci_identity_policy.k8s_instance_policy]

  node_config_details {
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[count.index].name
      subnet_id           = oci_core_subnet.vcn_private_subnet.id
    }
    size          = var.arm_pool_size
    freeform_tags = { "type" = "k8s" }
  }
  node_shape = "VM.Standard.A1.Flex"

  node_shape_config {
    memory_in_gbs = 6
    ocpus         = 1
  }

  node_source_details {
    image_id    = var.arm_pool_images[0]
    source_type = "image"
    boot_volume_size_in_gbs = 50
  }

  initial_node_labels {
    key   = "name"
    value = "k8s-cluster-pool-${count.index}"
  }

  ssh_public_key = var.ssh_public_key
}

# Container registry
resource "oci_artifacts_container_repository" "docker_repository" {
  compartment_id = var.compartment_id
  display_name   = "container_registry"
  is_immutable = false
  is_public    = false
}

resource "oci_core_volume" "arm_instance_volume" {
  count          = var.arm_pool_size
  compartment_id = var.compartment_id

  availability_domain = var.ad_list[count.index]
  size_in_gbs         = 50
  freeform_tags       = { "k8s-index" = count.index }
}

locals {
  storage_access_volumes = [
    for i, vol in oci_core_volume.arm_instance_volume : {
      index   = i
      ocid    = vol.id
      size_gb = vol.size_in_gbs
      zone    = element(split(":", vol.availability_domain), length(split(":", vol.availability_domain)) - 1)
    }
  ]
}

resource "null_resource" "storage_access" {
  triggers = {
    content_sha = sha256(templatefile("storage-access.yaml.tftpl", {
      volumes = local.storage_access_volumes
    }))
  }

  provisioner "local-exec" {
    working_dir = path.module
    command     = <<-EOT
      set -eu

      cat > ../manifests/provisioned/storage/storage-access.yaml <<'EOF'
${templatefile("storage-access.yaml.tftpl", {
  volumes = local.storage_access_volumes
})}
EOF
      chmod 0640 ../manifests/provisioned/storage/storage-access.yaml
    EOT
  }
}

resource "oci_identity_dynamic_group" "k8s_instances" {
  compartment_id = var.compartment_id
  description    = "k8s instances"
  matching_rule  = "instance.compartment.id = ${var.compartment_id}"
  # matching_rule   = "Any {instance.id = '${data.oci_containerengine_node_pool.k8s_node_pool[0].nodes[0].id}', instance.id =" '${data.oci_containerengine_node_pool.k8s_node_pool[1].nodes[0].id}'
  # matching_rule = "Any {" + join("instance.id = "${var.compartment_id}"
  name          = "k8s_instances"
  freeform_tags = { "Type" = "k8s" }
}

resource "oci_identity_policy" "k8s_instance_policy" {
  depends_on     = [oci_identity_dynamic_group.k8s_instances]
  compartment_id = var.compartment_id
  description    = "allow k8s instances to mount disks"
  name           = "k8s_allow_disks"
  statements = [
    "Allow dynamic-group k8s_instances to use instance-family in tenancy",
    "Allow dynamic-group k8s_instances to use volumes in tenancy",
    "Allow dynamic-group k8s_instances to manage volume-attachments in tenancy"
  ]
}

resource "oci_identity_policy" "k8s_instance_policy_metrics" {
  compartment_id = var.compartment_id
  description    = "allow k8s instances to read oci metrics"
  name           = "k8s_allow_oci_metrics"
  statements = [
    "Allow dynamic-group k8s_instances to read metrics in tenancy",
    "Allow dynamic-group k8s_instances to read compartments in tenancy"
  ]
}
