/**
 * Copyright 2024 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  _image = coalesce(var.node_config.image_type, "-")
  image = {
    is_cos = length(regexall("COS", local._image)) > 0
    is_cos_containerd = (
      var.node_config.image_type == null
      ||
      length(regexall("COS_CONTAINERD", local._image)) > 0
    )
    is_win = length(regexall("WIN", local._image)) > 0
  }
  node_metadata = var.node_config.metadata == null ? null : merge(
    var.node_config.metadata,
    { disable-legacy-endpoints = "true" }
  )
  # if no attributes passed for service account, use the GCE default
  # if no email specified, create service account
  service_account_email = (
    var.service_account.create
    ? google_service_account.service_account[0].email
    : var.service_account.email
  )
  service_account_scopes = (
    var.service_account.oauth_scopes != null
    ? var.service_account.oauth_scopes
    : [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/userinfo.email"
    ]
  )
  service_account_display_name = (
    var.service_account.display_name != null
    ? var.service_account.display_name
    : "Terraform GKE ${var.cluster_name} ${var.name}."
  )
  taints = merge(var.taints, !local.image.is_win ? {} : {
    "node.kubernetes.io/os" = {
      value  = "windows"
      effect = "NO_EXECUTE"
    }
  })
}

resource "google_service_account" "service_account" {
  count   = var.service_account.create ? 1 : 0
  project = var.project_id
  account_id = (
    var.service_account.email != null
    ? split("@", var.service_account.email)[0]
    : "tf-gke-${var.name}"
  )
  display_name = local.service_account_display_name
}

resource "google_container_node_pool" "nodepool" {
  provider           = google-beta
  project            = var.project_id
  cluster            = coalesce(var.cluster_id, var.cluster_name)
  location           = var.location
  name               = var.name
  version            = var.gke_version
  max_pods_per_node  = var.max_pods_per_node
  initial_node_count = var.node_count.initial
  node_count         = var.node_count.current
  node_locations     = var.node_locations

  dynamic "autoscaling" {
    for_each = (
      try(var.nodepool_config.autoscaling, null) != null
      &&
      !try(var.nodepool_config.autoscaling.use_total_nodes, false)
      ? [""] : []
    )
    content {
      location_policy = try(var.nodepool_config.autoscaling.location_policy, null)
      max_node_count  = try(var.nodepool_config.autoscaling.max_node_count, null)
      min_node_count  = try(var.nodepool_config.autoscaling.min_node_count, null)
    }
  }
  dynamic "autoscaling" {
    for_each = (
      try(var.nodepool_config.autoscaling.use_total_nodes, false) ? [""] : []
    )
    content {
      location_policy      = try(var.nodepool_config.autoscaling.location_policy, null)
      total_max_node_count = try(var.nodepool_config.autoscaling.max_node_count, null)
      total_min_node_count = try(var.nodepool_config.autoscaling.min_node_count, null)
    }
  }

  dynamic "management" {
    for_each = try(var.nodepool_config.management, null) != null ? [""] : []
    content {
      auto_repair  = try(var.nodepool_config.management.auto_repair, null)
      auto_upgrade = try(var.nodepool_config.management.auto_upgrade, null)
    }
  }

  dynamic "network_config" {
    for_each = var.network_config != null ? [""] : []
    content {
      create_pod_range     = var.network_config.pod_range.create
      enable_private_nodes = var.network_config.enable_private_nodes
      pod_ipv4_cidr_block  = var.network_config.pod_range.cidr
      pod_range            = var.network_config.pod_range.name
      dynamic "additional_node_network_configs" {
        for_each = try(var.network_config.additional_node_network_configs, [])
        content {
          network    = additional_node_network_configs.value.network
          subnetwork = additional_node_network_configs.value.subnetwork
        }
      }
      dynamic "additional_pod_network_configs" {
        for_each = try(var.network_config.additional_pod_network_configs, [])
        content {
          subnetwork          = additional_pod_network_configs.value.subnetwork
          secondary_pod_range = additional_pod_network_configs.value.secondary_pod_range
          max_pods_per_node   = additional_pod_network_configs.value.max_pods_per_node
        }
      }
      dynamic "network_performance_config" {
        for_each = try(var.network_config.total_egress_bandwidth_tier, null) != null ? [""] : []
        content {
          total_egress_bandwidth_tier = var.network_config.total_egress_bandwidth_tier
        }
      }
      dynamic "pod_cidr_overprovision_config" {
        for_each = var.network_config.pod_cidr_overprovisioning_disabled ? [""] : []
        content {
          disabled = true
        }
      }
    }
  }

  dynamic "upgrade_settings" {
    for_each = try(var.nodepool_config.upgrade_settings, null) != null ? [""] : []
    content {
      max_surge       = try(var.nodepool_config.upgrade_settings.max_surge, null)
      max_unavailable = try(var.nodepool_config.upgrade_settings.max_unavailable, null)
      strategy        = try(var.nodepool_config.upgrade_settings.strategy, null)
      dynamic "blue_green_settings" {
        for_each = try(var.nodepool_config.upgrade_settings.blue_green_settings, null) != null ? [""] : []
        content {
          node_pool_soak_duration = var.nodepool_config.upgrade_settings.blue_green_settings.node_pool_soak_duration
          dynamic "standard_rollout_policy" {
            for_each = try(var.nodepool_config.upgrade_settings.blue_green_settings.standard_rollout_policy, null) != null ? [""] : []
            content {
              batch_percentage    = var.nodepool_config.upgrade_settings.blue_green_settings.standard_rollout_policy.batch_percentage
              batch_node_count    = var.nodepool_config.upgrade_settings.blue_green_settings.standard_rollout_policy.batch_node_count
              batch_soak_duration = var.nodepool_config.upgrade_settings.blue_green_settings.standard_rollout_policy.batch_soak_duration
            }
          }
        }
      }
    }
  }

  dynamic "placement_policy" {
    for_each = try(var.nodepool_config.placement_policy, null) != null ? [""] : []
    content {
      type         = var.nodepool_config.placement_policy.type
      policy_name  = var.nodepool_config.placement_policy.policy_name
      tpu_topology = var.nodepool_config.placement_policy.tpu_topology
    }
  }

  dynamic "queued_provisioning" {
    for_each = try(var.nodepool_config.queued_provisioning, false) ? [""] : []
    content {
      enabled = var.nodepool_config.queued_provisioning
    }
  }

  node_config {
    boot_disk_kms_key = var.node_config.boot_disk_kms_key
    disk_size_gb      = var.node_config.disk_size_gb
    disk_type         = var.node_config.disk_type
    image_type        = var.node_config.image_type
    labels            = var.k8s_labels
    resource_labels   = var.labels
    local_ssd_count   = var.node_config.local_ssd_count
    machine_type      = var.node_config.machine_type
    metadata          = local.node_metadata
    min_cpu_platform  = var.node_config.min_cpu_platform
    node_group        = var.sole_tenant_nodegroup
    oauth_scopes      = local.service_account_scopes
    preemptible       = var.node_config.preemptible
    service_account   = local.service_account_email
    spot = (
      var.node_config.spot == true && var.node_config.preemptible != true
    )
    tags = var.tags

    dynamic "ephemeral_storage_config" {
      for_each = var.node_config.ephemeral_ssd_count != null ? [""] : []
      content {
        local_ssd_count = var.node_config.ephemeral_ssd_count
      }
    }
    dynamic "gcfs_config" {
      for_each = var.node_config.gcfs && local.image.is_cos_containerd ? [""] : []
      content {
        enabled = true
      }
    }
    dynamic "guest_accelerator" {
      for_each = var.node_config.guest_accelerator != null ? [""] : []
      content {
        count              = var.node_config.guest_accelerator.count
        type               = var.node_config.guest_accelerator.type
        gpu_partition_size = var.node_config.guest_accelerator.gpu_driver == null ? null : var.node_config.guest_accelerator.gpu_driver.partition_size

        dynamic "gpu_sharing_config" {
          for_each = try(var.node_config.guest_accelerator.gpu_driver.max_shared_clients_per_gpu, null) != null ? [""] : []
          content {
            gpu_sharing_strategy       = var.node_config.guest_accelerator.gpu_driver.max_shared_clients_per_gpu != null ? "TIME_SHARING" : null
            max_shared_clients_per_gpu = var.node_config.guest_accelerator.gpu_driver.max_shared_clients_per_gpu
          }
        }

        dynamic "gpu_driver_installation_config" {
          for_each = var.node_config.guest_accelerator.gpu_driver != null ? [""] : []
          content {
            gpu_driver_version = var.node_config.guest_accelerator.gpu_driver.version
          }
        }
      }
    }
    dynamic "local_nvme_ssd_block_config" {
      for_each = coalesce(var.node_config.local_nvme_ssd_count, 0) > 0 ? [""] : []
      content {
        local_ssd_count = var.node_config.local_nvme_ssd_count
      }
    }
    dynamic "gvnic" {
      for_each = var.node_config.gvnic && local.image.is_cos ? [""] : []
      content {
        enabled = true
      }
    }
    dynamic "kubelet_config" {
      for_each = var.node_config.kubelet_config != null ? [""] : []
      content {
        cpu_manager_policy                     = var.node_config.kubelet_config.cpu_manager_policy
        cpu_cfs_quota                          = var.node_config.kubelet_config.cpu_cfs_quota
        cpu_cfs_quota_period                   = var.node_config.kubelet_config.cpu_cfs_quota_period
        insecure_kubelet_readonly_port_enabled = var.node_config.kubelet_config.insecure_kubelet_readonly_port_enabled
        pod_pids_limit                         = var.node_config.kubelet_config.pod_pids_limit
        container_log_max_size                 = var.node_config.kubelet_config.container_log_max_size
        container_log_max_files                = var.node_config.kubelet_config.container_log_max_files
        image_gc_low_threshold_percent         = var.node_config.kubelet_config.image_gc_low_threshold_percent
        image_gc_high_threshold_percent        = var.node_config.kubelet_config.image_gc_high_threshold_percent
        image_minimum_gc_age                   = var.node_config.kubelet_config.image_minimum_gc_age
        image_maximum_gc_age                   = var.node_config.kubelet_config.image_maximum_gc_age
        allowed_unsafe_sysctls                 = var.node_config.kubelet_config.allowed_unsafe_sysctls
      }
    }
    dynamic "linux_node_config" {
      for_each = var.node_config.linux_node_config != null ? [""] : []
      content {
        sysctls     = var.node_config.linux_node_config.sysctls
        cgroup_mode = try(var.node_config.linux_node_config.cgroup_mode, "CGROUP_MODE_UNSPECIFIED")
      }
    }
    dynamic "reservation_affinity" {
      for_each = var.reservation_affinity != null ? [""] : []
      content {
        consume_reservation_type = var.reservation_affinity.consume_reservation_type
        key                      = var.reservation_affinity.key
        values                   = var.reservation_affinity.values
      }
    }
    dynamic "sandbox_config" {
      for_each = (
        var.node_config.sandbox_config_gvisor == true &&
        local.image.is_cos_containerd != null
        ? [""]
        : []
      )
      content {
        sandbox_type = "gvisor"
      }
    }
    dynamic "shielded_instance_config" {
      for_each = var.node_config.shielded_instance_config != null ? [""] : []
      content {
        enable_secure_boot          = var.node_config.shielded_instance_config.enable_secure_boot
        enable_integrity_monitoring = var.node_config.shielded_instance_config.enable_integrity_monitoring
      }
    }
    dynamic "taint" {
      for_each = local.taints
      content {
        key    = taint.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }
    dynamic "workload_metadata_config" {
      for_each = var.node_config.workload_metadata_config_mode != null ? [""] : []
      content {
        mode = var.node_config.workload_metadata_config_mode
      }
    }
  }
}
