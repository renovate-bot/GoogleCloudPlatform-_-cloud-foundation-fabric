# Internal Application Load Balancer Module

This module allows managing Internal HTTP/HTTPS Load Balancers (L7 ILBs). It's designed to expose the full configuration of the underlying resources, and to facilitate common usage patterns by providing sensible defaults, and optionally managing prerequisite resources like health checks, instance groups, etc.

Due to the complexity of the underlying resources, changes to the configuration that involve recreation of resources are best applied in stages, starting by disabling the configuration in the urlmap that references the resources that need recreation, then doing the same for the backend service, etc.

## Examples

<!-- BEGIN TOC -->
- [Examples](#examples)
  - [Minimal Example](#minimal-example)
  - [Cross-project backend services](#cross-project-backend-services)
  - [Health Checks](#health-checks)
  - [Instance Groups](#instance-groups)
  - [Network Endpoint Groups (NEGs)](#network-endpoint-groups-negs)
    - [Zonal NEG creation](#zonal-neg-creation)
    - [Hybrid NEG creation](#hybrid-neg-creation)
    - [Serverless NEG creation](#serverless-neg-creation)
    - [Private Service Connect NEG creation](#private-service-connect-neg-creation)
    - [Internet NEG creation](#internet-neg-creation)
  - [URL Map](#url-map)
  - [SSL Certificates](#ssl-certificates)
  - [PSC service attachment](#psc-service-attachment)
  - [Complex example](#complex-example)
- [Deploying changes to load balancer configurations](#deploying-changes-to-load-balancer-configurations)
- [Files](#files)
- [Variables](#variables)
- [Outputs](#outputs)
- [Fixtures](#fixtures)
<!-- END TOC -->

### Minimal Example

An HTTP ILB with a backend service pointing to a GCE instance group:

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        group = "projects/myprj/zones/europe-west1-a/instanceGroups/my-ig"
      }]
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=5
```

An HTTPS ILB needs a few additional fields:

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        group = "projects/myprj/zones/europe-west1-a/instanceGroups/my-ig"
      }]
    }
  }
  protocol = "HTTPS"
  ssl_certificates = {
    certificate_ids = [
      "projects/myprj/regions/europe-west1/sslCertificates/my-cert"
    ]
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=5
```

### Cross-project backend services

When using Shared VPC, this module also allows configuring [cross-project backend services](https://cloud.google.com/load-balancing/docs/l7-internal/l7-internal-shared-vpc#cross-project):

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = "prj-host"
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      project_id = "prj-svc"
      backends = [{
        group = "projects/prj-svc/zones/europe-west1-a/instanceGroups/my-ig"
      }]
    }
  }
  health_check_configs = {
    default = {
      project_id = "prj-svc"
      http = {
        port_specification = "USE_SERVING_PORT"
      }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=5
```

### Health Checks

You can leverage externally defined health checks for backend services, or have the module create them for you. By default a simple HTTP health check is created, and used in backend services.

Health check configuration is controlled via the `health_check_configs` variable, which behaves in a similar way to other LB modules in this repository.

Defining different health checks from the default is very easy. You can for example replace the default HTTP health check with a TCP one and reference it in you backend service:

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        group = "projects/myprj/zones/europe-west1-a/instanceGroups/my-ig"
      }]
      health_checks = ["custom-tcp"]
    }
  }
  health_check_configs = {
    custom-tcp = {
      tcp = { port = 80 }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=5
```

To leverage existing health checks without having the module create them, simply pass their self links to backend services and set the `health_check_configs` variable to an empty map:

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        group = "projects/myprj/zones/europe-west1-a/instanceGroups/my-ig"
      }]
      health_checks = ["projects/myprj/global/healthChecks/custom"]
    }
  }
  health_check_configs = {}
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=4
```

### Instance Groups

The module can optionally create unmanaged instance groups, which can then be referred to in backends via their key:

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      port_name = "http"
      backends = [
        { group = "default" }
      ]
    }
  }
  group_configs = {
    default = {
      zone = "europe-west1-b"
      instances = [
        "projects/myprj/zones/europe-west1-b/instances/vm-a"
      ]
      named_ports = { http = 80 }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=6
```

### Network Endpoint Groups (NEGs)

Network Endpoint Groups (NEGs) can be used as backends, by passing their id as the backend group in a backends service configuration:

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        balancing_mode = "RATE"
        group          = "projects/myprj/zones/europe-west1-a/networkEndpointGroups/my-neg"
        max_rate = {
          per_endpoint = 1
        }
      }]
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=5
```

Similarly to instance groups, NEGs can also be managed by this module which supports GCE, hybrid, serverless and Private Service Connect NEGs:

#### Zonal NEG creation

```hcl
resource "google_compute_address" "test" {
  project      = var.project_id
  name         = "neg-test"
  subnetwork   = var.subnet.self_link
  address_type = "INTERNAL"
  address      = "10.0.0.10"
  region       = "europe-west1"
}

module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        balancing_mode = "RATE"
        group          = "my-neg"
        max_rate = {
          per_endpoint = 1
        }
      }]
    }
  }
  neg_configs = {
    my-neg = {
      gce = {
        zone = "europe-west1-b"
        endpoints = {
          e-0 = {
            instance   = "test-1"
            ip_address = google_compute_address.test.address
            # ip_address = "10.0.0.10"
            port = 80
          }
        }
      }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=8 inventory=zonal-neg.yaml
```

#### Hybrid NEG creation

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        balancing_mode = "RATE"
        group          = "my-neg"
        max_rate = {
          per_endpoint = 1
        }
      }]
    }
  }
  neg_configs = {
    my-neg = {
      hybrid = {
        zone = "europe-west1-b"
        endpoints = {
          e-0 = {
            ip_address = "10.0.0.10"
            port       = 80
          }
        }
      }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=7
```

#### Serverless NEG creation

This is a simple example where both the Cloud Run service and the load balancer are in the same project.

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        group = "my-neg"
      }]
      health_checks = []
      protocol      = "HTTPS"
    }
  }
  health_check_configs = {}
  neg_configs = {
    my-neg = {
      cloudrun = {
        region = "europe-west1"
        target_service = {
          name = "my-run-service"
        }
      }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=5
```

For cross-project referencing, both the load balancer and the cloud run projects need to be service projects of the same Shared VPC host. Then specify the Cloud Run project for both the backend service and NEG.

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        group = "my-neg"
      }]
      health_checks = []
      protocol      = "HTTPS"
      project_id    = "cr-project-id"
    }
  }
  health_check_configs = {}
  neg_configs = {
    my-neg = {
      project_id = "cr-project-id"
      cloudrun = {
        region = "europe-west1"
        target_service = {
          name = "my-run-service"
        }
      }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=5
```

#### Private Service Connect NEG creation

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = var.region
  backend_service_configs = {
    default = {
      backends = [{
        group = "my-neg"
      }]
      health_checks = []
    }
  }
  health_check_configs = {}
  neg_configs = {
    my-neg = {
      psc = {
        region         = var.region
        target_service = "${var.region}-cloudkms.googleapis.com"
      }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=5 e2e
```

#### Internet NEG creation

This example shows how to create and manage internet NEGs:

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  project_id = var.project_id
  name       = "ilb-test"
  region     = var.region
  backend_service_configs = {
    default = {
      backends = [
        { group = "neg-0" }
      ]
      health_checks = []
    }
  }
  # with a single internet NEG the implied default health check is not needed
  health_check_configs = {}
  neg_configs = {
    neg-0 = {
      internet = {
        region   = var.region
        use_fqdn = true
        endpoints = {
          e-0 = {
            destination = "www.example.org"
            port        = 80
          }
        }
      }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=6 inventory=internet-neg.yaml e2e
```

### URL Map

The module exposes the full URL map resource configuration, with some minor changes to the interface to decrease verbosity, and support for aliasing backend services via keys.

The default URL map configuration sets the `default` backend service as the default service for the load balancer as a convenience. Just override the `urlmap_config` variable to change the default behaviour:

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        group = "projects/myprj/zones/europe-west1-a/instanceGroups/my-ig"
      }]
    }
    video = {
      backends = [{
        group = "projects/myprj/zones/europe-west1-a/instanceGroups/my-ig-2"
      }]
    }
  }
  urlmap_config = {
    default_service = "default"
    host_rules = [{
      hosts        = ["*"]
      path_matcher = "pathmap"
    }]
    path_matchers = {
      pathmap = {
        default_service = "default"
        path_rules = [{
          paths   = ["/video", "/video/*"]
          service = "video"
        }]
      }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}

# tftest modules=1 resources=6
```

### SSL Certificates

Similarly to health checks, SSL certificates can also be created by the module. In this example we are using private key and certificate resources so that the example test only depends on Terraform providers, but in real use those can be replaced by external files.

```hcl

resource "tls_private_key" "default" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "default" {
  private_key_pem = tls_private_key.default.private_key_pem
  subject {
    common_name  = "example.com"
    organization = "ACME Examples, Inc"
  }
  validity_period_hours = 720
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = "europe-west1"
  backend_service_configs = {
    default = {
      backends = [{
        group = "projects/myprj/zones/europe-west1-a/instanceGroups/my-ig"
      }]
    }
  }
  health_check_configs = {
    default = {
      https = { port = 443 }
    }
  }
  protocol = "HTTPS"
  ssl_certificates = {
    create_configs = {
      default = {
        # certificate and key could also be read via file() from external files
        certificate = tls_self_signed_cert.default.cert_pem
        private_key = tls_private_key.default.private_key_pem
      }
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
}
# tftest modules=1 resources=8
```

### PSC service attachment

The optional `service_attachment` variable allows [publishing Private Service Connect service](https://cloud.google.com/vpc/docs/configure-private-service-connect-producer) by configuring service attachment for the forwarding rule.

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-test"
  project_id = var.project_id
  region     = var.region
  backend_service_configs = {
    default = {
      backends = [{
        group = module.compute-vm-group-b.group.id
      }]
    }
  }
  vpc_config = {
    network    = var.vpc.self_link
    subnetwork = var.subnet.self_link
  }
  service_attachment = {
    nat_subnets          = [var.subnet_psc_1.self_link]
    automatic_connection = false
    consumer_accept_lists = {
      # map of `project_id` => `connection_limit`
      (var.project_id) = 10
    }
  }
}
# tftest modules=3 resources=10 fixtures=fixtures/compute-vm-group-bc.tf e2e
```

### Complex example

This example mixes group and NEG backends, and shows how to set HTTPS for specific backends.

```hcl
module "ilb-l7" {
  source     = "./fabric/modules/net-lb-app-int"
  name       = "ilb-l7-test-0"
  project_id = "prj-gce"
  region     = "europe-west8"
  backend_service_configs = {
    default = {
      backends = [
        { group = "nginx-ew8-b" },
        { group = "nginx-ew8-c" },
      ]
    }
    gce-neg = {
      backends = [{
        balancing_mode = "RATE"
        group          = "neg-nginx-ew8-c"
        max_rate = {
          per_endpoint = 1
        }
      }]
    }
    home = {
      backends = [{
        balancing_mode = "RATE"
        group          = "neg-home-hello"
        max_rate = {
          per_endpoint = 1
        }
      }]
      health_checks      = ["neg"]
      locality_lb_policy = "ROUND_ROBIN"
      protocol           = "HTTPS"
    }
  }
  group_configs = {
    nginx-ew8-b = {
      zone = "europe-west8-b"
      instances = [
        "projects/prj-gce/zones/europe-west8-b/instances/nginx-ew8-b"
      ]
      named_ports = { http = 80 }
    }
    nginx-ew8-c = {
      zone = "europe-west8-c"
      instances = [
        "projects/prj-gce/zones/europe-west8-c/instances/nginx-ew8-c"
      ]
      named_ports = { http = 80 }
    }
  }
  health_check_configs = {
    default = {
      http = {
        port = 80
      }
    }
    neg = {
      https = {
        host = "hello.home.example.com"
        port = 443
      }
    }
  }
  neg_configs = {
    neg-nginx-ew8-c = {
      gce = {
        zone = "europe-west8-c"
        endpoints = {
          e-0 = {
            instance   = "nginx-ew8-c"
            ip_address = "10.24.32.26"
            port       = 80
          }
        }
      }
    }
    neg-home-hello = {
      hybrid = {
        zone = "europe-west8-b"
        endpoints = {
          e-0 = {
            ip_address = "192.168.0.3"
            port       = 443
          }
        }
      }
    }
  }
  urlmap_config = {
    default_service = "default"
    host_rules = [
      {
        hosts        = ["*"]
        path_matcher = "gce"
      },
      {
        hosts        = ["hello.home.example.com"]
        path_matcher = "home"
      }
    ]
    path_matchers = {
      gce = {
        default_service = "default"
        path_rules = [
          {
            paths   = ["/gce-neg", "/gce-neg/*"]
            service = "gce-neg"
          }
        ]
      }
      home = {
        default_service = "home"
      }
    }
  }
  vpc_config = {
    network    = "projects/prj-host/global/networks/shared-vpc"
    subnetwork = "projects/prj-host/regions/europe-west8/subnetworks/gce"
  }
}
# tftest modules=1 resources=14
```

## Deploying changes to load balancer configurations

For deploying changes to load balancer configuration please refer to [net-lb-app-ext README.md](../net-lb-app-ext/README.md#deploying-changes-to-load-balancer-configurations)

<!-- TFDOC OPTS files:1 -->
<!-- BEGIN TFDOC -->
## Files

| name | description | resources |
|---|---|---|
| [backend-service.tf](./backend-service.tf) | Backend service resources. | <code>google_compute_region_backend_service</code> |
| [groups.tf](./groups.tf) | None | <code>google_compute_instance_group</code> |
| [health-check.tf](./health-check.tf) | Health check resource. | <code>google_compute_health_check</code> |
| [main.tf](./main.tf) | Module-level locals and resources. | <code>google_compute_forwarding_rule</code> · <code>google_compute_network_endpoint</code> · <code>google_compute_network_endpoint_group</code> · <code>google_compute_region_network_endpoint</code> · <code>google_compute_region_network_endpoint_group</code> · <code>google_compute_region_ssl_certificate</code> · <code>google_compute_region_target_http_proxy</code> · <code>google_compute_region_target_https_proxy</code> · <code>google_compute_service_attachment</code> |
| [outputs.tf](./outputs.tf) | Module outputs. |  |
| [urlmap.tf](./urlmap.tf) | URL map resources. | <code>google_compute_region_url_map</code> |
| [variables-backend-service.tf](./variables-backend-service.tf) | Backend services variables. |  |
| [variables-health-check.tf](./variables-health-check.tf) | Health check variable. |  |
| [variables-urlmap.tf](./variables-urlmap.tf) | URLmap variable. |  |
| [variables.tf](./variables.tf) | Module variables. |  |
| [versions.tf](./versions.tf) | Version pins. |  |

## Variables

| name | description | type | required | default |
|---|---|:---:|:---:|:---:|
| [name](variables.tf#L66) | Load balancer name. | <code>string</code> | ✓ |  |
| [project_id](variables.tf#L166) | Project id. | <code>string</code> | ✓ |  |
| [region](variables.tf#L184) | The region where to allocate the ILB resources. | <code>string</code> | ✓ |  |
| [vpc_config](variables.tf#L227) | VPC-level configuration. | <code title="object&#40;&#123;&#10;  network    &#61; string&#10;  subnetwork &#61; string&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> | ✓ |  |
| [address](variables.tf#L17) | Optional IP address used for the forwarding rule. | <code>string</code> |  | <code>null</code> |
| [backend_service_configs](variables-backend-service.tf#L19) | Backend service level configuration. | <code title="map&#40;object&#40;&#123;&#10;  name                            &#61; optional&#40;string&#41;&#10;  description                     &#61; optional&#40;string, &#34;Terraform managed.&#34;&#41;&#10;  affinity_cookie_ttl_sec         &#61; optional&#40;number&#41;&#10;  connection_draining_timeout_sec &#61; optional&#40;number&#41;&#10;  health_checks                   &#61; optional&#40;list&#40;string&#41;, &#91;&#34;default&#34;&#93;&#41;&#10;  locality_lb_policy              &#61; optional&#40;string&#41;&#10;  log_sample_rate                 &#61; optional&#40;number&#41;&#10;  port_name                       &#61; optional&#40;string&#41;&#10;  project_id                      &#61; optional&#40;string&#41;&#10;  protocol                        &#61; optional&#40;string&#41;&#10;  session_affinity                &#61; optional&#40;string&#41;&#10;  timeout_sec                     &#61; optional&#40;number&#41;&#10;  security_policy                 &#61; optional&#40;string&#41;&#10;  backends &#61; list&#40;object&#40;&#123;&#10;    group           &#61; string&#10;    balancing_mode  &#61; optional&#40;string, &#34;UTILIZATION&#34;&#41;&#10;    capacity_scaler &#61; optional&#40;number, 1&#41;&#10;    description     &#61; optional&#40;string, &#34;Terraform managed.&#34;&#41;&#10;    failover        &#61; optional&#40;bool, false&#41;&#10;    max_rate &#61; optional&#40;object&#40;&#123;&#10;      per_endpoint &#61; optional&#40;number&#41;&#10;      per_group    &#61; optional&#40;number&#41;&#10;      per_instance &#61; optional&#40;number&#41;&#10;    &#125;&#41;&#41;&#10;    max_utilization &#61; optional&#40;number&#41;&#10;  &#125;&#41;&#41;&#10;  circuit_breakers &#61; optional&#40;object&#40;&#123;&#10;    max_connections             &#61; optional&#40;number&#41;&#10;    max_pending_requests        &#61; optional&#40;number&#41;&#10;    max_requests                &#61; optional&#40;number&#41;&#10;    max_requests_per_connection &#61; optional&#40;number&#41;&#10;    max_retries                 &#61; optional&#40;number&#41;&#10;    connect_timeout &#61; optional&#40;object&#40;&#123;&#10;      seconds &#61; number&#10;      nanos   &#61; optional&#40;number&#41;&#10;    &#125;&#41;&#41;&#10;  &#125;&#41;&#41;&#10;  consistent_hash &#61; optional&#40;object&#40;&#123;&#10;    http_header_name  &#61; optional&#40;string&#41;&#10;    minimum_ring_size &#61; optional&#40;number&#41;&#10;    http_cookie &#61; optional&#40;object&#40;&#123;&#10;      name &#61; optional&#40;string&#41;&#10;      path &#61; optional&#40;string&#41;&#10;      ttl &#61; optional&#40;object&#40;&#123;&#10;        seconds &#61; number&#10;        nanos   &#61; optional&#40;number&#41;&#10;      &#125;&#41;&#41;&#10;    &#125;&#41;&#41;&#10;  &#125;&#41;&#41;&#10;  enable_subsetting &#61; optional&#40;bool&#41;&#10;  failover_config &#61; optional&#40;object&#40;&#123;&#10;    disable_conn_drain        &#61; optional&#40;bool&#41;&#10;    drop_traffic_if_unhealthy &#61; optional&#40;bool&#41;&#10;  &#125;&#41;&#41;&#10;  iap_config &#61; optional&#40;object&#40;&#123;&#10;    oauth2_client_id            &#61; optional&#40;string&#41;&#10;    oauth2_client_secret        &#61; optional&#40;string&#41;&#10;    oauth2_client_secret_sha256 &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#10;  outlier_detection &#61; optional&#40;object&#40;&#123;&#10;    consecutive_errors                    &#61; optional&#40;number&#41;&#10;    consecutive_gateway_failure           &#61; optional&#40;number&#41;&#10;    enforcing_consecutive_errors          &#61; optional&#40;number&#41;&#10;    enforcing_consecutive_gateway_failure &#61; optional&#40;number&#41;&#10;    enforcing_success_rate                &#61; optional&#40;number&#41;&#10;    max_ejection_percent                  &#61; optional&#40;number&#41;&#10;    success_rate_minimum_hosts            &#61; optional&#40;number&#41;&#10;    success_rate_request_volume           &#61; optional&#40;number&#41;&#10;    success_rate_stdev_factor             &#61; optional&#40;number&#41;&#10;    base_ejection_time &#61; optional&#40;object&#40;&#123;&#10;      seconds &#61; number&#10;      nanos   &#61; optional&#40;number&#41;&#10;    &#125;&#41;&#41;&#10;    interval &#61; optional&#40;object&#40;&#123;&#10;      seconds &#61; number&#10;      nanos   &#61; optional&#40;number&#41;&#10;    &#125;&#41;&#41;&#10;  &#125;&#41;&#41;&#10;&#125;&#41;&#41;">map&#40;object&#40;&#123;&#8230;&#125;&#41;&#41;</code> |  | <code>&#123;&#125;</code> |
| [description](variables.tf#L23) | Optional description used for resources. | <code>string</code> |  | <code>&#34;Terraform managed.&#34;</code> |
| [global_access](variables.tf#L30) | Allow client access from all regions. | <code>bool</code> |  | <code>null</code> |
| [group_configs](variables.tf#L36) | Optional unmanaged groups to create. Can be referenced in backends via key or outputs. | <code title="map&#40;object&#40;&#123;&#10;  zone        &#61; string&#10;  instances   &#61; optional&#40;list&#40;string&#41;&#41;&#10;  named_ports &#61; optional&#40;map&#40;number&#41;, &#123;&#125;&#41;&#10;  project_id  &#61; optional&#40;string&#41;&#10;&#125;&#41;&#41;">map&#40;object&#40;&#123;&#8230;&#125;&#41;&#41;</code> |  | <code>&#123;&#125;</code> |
| [health_check_configs](variables-health-check.tf#L19) | Optional auto-created health check configurations, use the output self-link to set it in the auto healing policy. Refer to examples for usage. | <code title="map&#40;object&#40;&#123;&#10;  name                &#61; optional&#40;string&#41;&#10;  check_interval_sec  &#61; optional&#40;number&#41;&#10;  description         &#61; optional&#40;string, &#34;Terraform managed.&#34;&#41;&#10;  enable_logging      &#61; optional&#40;bool, false&#41;&#10;  healthy_threshold   &#61; optional&#40;number&#41;&#10;  project_id          &#61; optional&#40;string&#41;&#10;  timeout_sec         &#61; optional&#40;number&#41;&#10;  unhealthy_threshold &#61; optional&#40;number&#41;&#10;  grpc &#61; optional&#40;object&#40;&#123;&#10;    port               &#61; optional&#40;number&#41;&#10;    port_name          &#61; optional&#40;string&#41;&#10;    port_specification &#61; optional&#40;string&#41; &#35; USE_FIXED_PORT USE_NAMED_PORT USE_SERVING_PORT&#10;    service_name       &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#10;  http &#61; optional&#40;object&#40;&#123;&#10;    host               &#61; optional&#40;string&#41;&#10;    port               &#61; optional&#40;number&#41;&#10;    port_name          &#61; optional&#40;string&#41;&#10;    port_specification &#61; optional&#40;string&#41; &#35; USE_FIXED_PORT USE_NAMED_PORT USE_SERVING_PORT&#10;    proxy_header       &#61; optional&#40;string&#41;&#10;    request_path       &#61; optional&#40;string&#41;&#10;    response           &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#10;  http2 &#61; optional&#40;object&#40;&#123;&#10;    host               &#61; optional&#40;string&#41;&#10;    port               &#61; optional&#40;number&#41;&#10;    port_name          &#61; optional&#40;string&#41;&#10;    port_specification &#61; optional&#40;string&#41; &#35; USE_FIXED_PORT USE_NAMED_PORT USE_SERVING_PORT&#10;    proxy_header       &#61; optional&#40;string&#41;&#10;    request_path       &#61; optional&#40;string&#41;&#10;    response           &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#10;  https &#61; optional&#40;object&#40;&#123;&#10;    host               &#61; optional&#40;string&#41;&#10;    port               &#61; optional&#40;number&#41;&#10;    port_name          &#61; optional&#40;string&#41;&#10;    port_specification &#61; optional&#40;string&#41; &#35; USE_FIXED_PORT USE_NAMED_PORT USE_SERVING_PORT&#10;    proxy_header       &#61; optional&#40;string&#41;&#10;    request_path       &#61; optional&#40;string&#41;&#10;    response           &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#10;  tcp &#61; optional&#40;object&#40;&#123;&#10;    port               &#61; optional&#40;number&#41;&#10;    port_name          &#61; optional&#40;string&#41;&#10;    port_specification &#61; optional&#40;string&#41; &#35; USE_FIXED_PORT USE_NAMED_PORT USE_SERVING_PORT&#10;    proxy_header       &#61; optional&#40;string&#41;&#10;    request            &#61; optional&#40;string&#41;&#10;    response           &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#10;  ssl &#61; optional&#40;object&#40;&#123;&#10;    port               &#61; optional&#40;number&#41;&#10;    port_name          &#61; optional&#40;string&#41;&#10;    port_specification &#61; optional&#40;string&#41; &#35; USE_FIXED_PORT USE_NAMED_PORT USE_SERVING_PORT&#10;    proxy_header       &#61; optional&#40;string&#41;&#10;    request            &#61; optional&#40;string&#41;&#10;    response           &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#10;&#125;&#41;&#41;">map&#40;object&#40;&#123;&#8230;&#125;&#41;&#41;</code> |  | <code title="&#123;&#10;  default &#61; &#123;&#10;    http &#61; &#123;&#10;      port_specification &#61; &#34;USE_SERVING_PORT&#34;&#10;    &#125;&#10;  &#125;&#10;&#125;">&#123;&#8230;&#125;</code> |
| [https_proxy_config](variables.tf#L48) | HTTPS proxy configuration. | <code title="object&#40;&#123;&#10;  name                             &#61; optional&#40;string&#41;&#10;  description                      &#61; optional&#40;string, &#34;Terraform managed.&#34;&#41;&#10;  certificate_manager_certificates &#61; optional&#40;list&#40;string&#41;&#41;&#10;  ssl_policy                       &#61; optional&#40;string&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code>&#123;&#125;</code> |
| [labels](variables.tf#L60) | Labels set on resources. | <code>map&#40;string&#41;</code> |  | <code>&#123;&#125;</code> |
| [neg_configs](variables.tf#L71) | Optional network endpoint groups to create. Can be referenced in backends via key or outputs. | <code title="map&#40;object&#40;&#123;&#10;  project_id  &#61; optional&#40;string&#41;&#10;  description &#61; optional&#40;string&#41;&#10;  cloudrun &#61; optional&#40;object&#40;&#123;&#10;    region &#61; string&#10;    target_service &#61; optional&#40;object&#40;&#123;&#10;      name &#61; string&#10;      tag  &#61; optional&#40;string&#41;&#10;    &#125;&#41;&#41;&#10;    target_urlmask &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#10;  gce &#61; optional&#40;object&#40;&#123;&#10;    zone &#61; string&#10;    network    &#61; optional&#40;string&#41;&#10;    subnetwork &#61; optional&#40;string&#41;&#10;    endpoints &#61; optional&#40;map&#40;object&#40;&#123;&#10;      instance   &#61; string&#10;      ip_address &#61; string&#10;      port       &#61; number&#10;    &#125;&#41;&#41;&#41;&#10;&#10;&#10;  &#125;&#41;&#41;&#10;  hybrid &#61; optional&#40;object&#40;&#123;&#10;    zone    &#61; string&#10;    network &#61; optional&#40;string&#41;&#10;    endpoints &#61; optional&#40;map&#40;object&#40;&#123;&#10;      ip_address &#61; string&#10;      port       &#61; number&#10;    &#125;&#41;&#41;&#41;&#10;  &#125;&#41;&#41;&#10;  internet &#61; optional&#40;object&#40;&#123;&#10;    region   &#61; string&#10;    use_fqdn &#61; optional&#40;bool, true&#41;&#10;    endpoints &#61; optional&#40;map&#40;object&#40;&#123;&#10;      destination &#61; string&#10;      port        &#61; number&#10;    &#125;&#41;&#41;&#41;&#10;  &#125;&#41;&#41;&#10;  psc &#61; optional&#40;object&#40;&#123;&#10;    region         &#61; string&#10;    target_service &#61; string&#10;    network        &#61; optional&#40;string&#41;&#10;    subnetwork     &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#10;&#125;&#41;&#41;">map&#40;object&#40;&#123;&#8230;&#125;&#41;&#41;</code> |  | <code>&#123;&#125;</code> |
| [network_tier_premium](variables.tf#L149) | Use premium network tier. Defaults to true. | <code>bool</code> |  | <code>true</code> |
| [ports](variables.tf#L156) | Optional ports for HTTP load balancer. | <code>list&#40;string&#41;</code> |  | <code>null</code> |
| [protocol](variables.tf#L171) | Protocol supported by this load balancer. | <code>string</code> |  | <code>&#34;HTTP&#34;</code> |
| [service_attachment](variables.tf#L189) | PSC service attachment. | <code title="object&#40;&#123;&#10;  nat_subnets           &#61; list&#40;string&#41;&#10;  automatic_connection  &#61; optional&#40;bool, false&#41;&#10;  consumer_accept_lists &#61; optional&#40;map&#40;string&#41;, &#123;&#125;&#41;&#10;  consumer_reject_lists &#61; optional&#40;list&#40;string&#41;&#41;&#10;  description           &#61; optional&#40;string&#41;&#10;  domain_name           &#61; optional&#40;string&#41;&#10;  enable_proxy_protocol &#61; optional&#40;bool, false&#41;&#10;  reconcile_connections &#61; optional&#40;bool&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code>null</code> |
| [service_directory_registration](variables.tf#L204) | Service directory namespace and service used to register this load balancer. | <code title="object&#40;&#123;&#10;  namespace &#61; string&#10;  service   &#61; string&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code>null</code> |
| [ssl_certificates](variables.tf#L213) | SSL target proxy certificates (only if protocol is HTTPS). | <code title="object&#40;&#123;&#10;  certificate_ids &#61; optional&#40;list&#40;string&#41;, &#91;&#93;&#41;&#10;  create_configs &#61; optional&#40;map&#40;object&#40;&#123;&#10;    name        &#61; optional&#40;string&#41;&#10;    certificate &#61; string&#10;    private_key &#61; string&#10;  &#125;&#41;&#41;, &#123;&#125;&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code>&#123;&#125;</code> |
| [urlmap_config](variables-urlmap.tf#L19) | The URL map configuration. | <code title="object&#40;&#123;&#10;  description     &#61; optional&#40;string, &#34;Terraform managed.&#34;&#41;&#10;  default_service &#61; optional&#40;string&#41;&#10;  default_url_redirect &#61; optional&#40;object&#40;&#123;&#10;    host          &#61; optional&#40;string&#41;&#10;    https         &#61; optional&#40;bool&#41;&#10;    path          &#61; optional&#40;string&#41;&#10;    prefix        &#61; optional&#40;string&#41;&#10;    response_code &#61; optional&#40;string&#41;&#10;    strip_query   &#61; optional&#40;bool&#41;&#10;  &#125;&#41;&#41;&#10;  host_rules &#61; optional&#40;list&#40;object&#40;&#123;&#10;    hosts        &#61; list&#40;string&#41;&#10;    path_matcher &#61; string&#10;    description  &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#41;&#10;  path_matchers &#61; optional&#40;map&#40;object&#40;&#123;&#10;    description     &#61; optional&#40;string&#41;&#10;    default_service &#61; optional&#40;string&#41;&#10;    default_url_redirect &#61; optional&#40;object&#40;&#123;&#10;      host          &#61; optional&#40;string&#41;&#10;      https         &#61; optional&#40;bool&#41;&#10;      path          &#61; optional&#40;string&#41;&#10;      prefix        &#61; optional&#40;string&#41;&#10;      response_code &#61; optional&#40;string&#41;&#10;      strip_query   &#61; optional&#40;bool&#41;&#10;    &#125;&#41;&#41;&#10;    path_rules &#61; optional&#40;list&#40;object&#40;&#123;&#10;      paths   &#61; list&#40;string&#41;&#10;      service &#61; optional&#40;string&#41;&#10;      route_action &#61; optional&#40;object&#40;&#123;&#10;        request_mirror_backend &#61; optional&#40;string&#41;&#10;        cors_policy &#61; optional&#40;object&#40;&#123;&#10;          allow_credentials    &#61; optional&#40;bool&#41;&#10;          allow_headers        &#61; optional&#40;list&#40;string&#41;&#41;&#10;          allow_methods        &#61; optional&#40;list&#40;string&#41;&#41;&#10;          allow_origin_regexes &#61; optional&#40;list&#40;string&#41;&#41;&#10;          allow_origins        &#61; optional&#40;list&#40;string&#41;&#41;&#10;          disabled             &#61; optional&#40;bool&#41;&#10;          expose_headers       &#61; optional&#40;list&#40;string&#41;&#41;&#10;          max_age              &#61; optional&#40;string&#41;&#10;        &#125;&#41;&#41;&#10;        fault_injection_policy &#61; optional&#40;object&#40;&#123;&#10;          abort &#61; optional&#40;object&#40;&#123;&#10;            percentage &#61; number&#10;            status     &#61; number&#10;          &#125;&#41;&#41;&#10;          delay &#61; optional&#40;object&#40;&#123;&#10;            fixed &#61; object&#40;&#123;&#10;              seconds &#61; number&#10;              nanos   &#61; number&#10;            &#125;&#41;&#10;            percentage &#61; number&#10;          &#125;&#41;&#41;&#10;        &#125;&#41;&#41;&#10;        retry_policy &#61; optional&#40;object&#40;&#123;&#10;          num_retries      &#61; number&#10;          retry_conditions &#61; optional&#40;list&#40;string&#41;&#41;&#10;          per_try_timeout &#61; optional&#40;object&#40;&#123;&#10;            seconds &#61; number&#10;            nanos   &#61; optional&#40;number&#41;&#10;          &#125;&#41;&#41;&#10;        &#125;&#41;&#41;&#10;        timeout &#61; optional&#40;object&#40;&#123;&#10;          seconds &#61; number&#10;          nanos   &#61; optional&#40;number&#41;&#10;        &#125;&#41;&#41;&#10;        url_rewrite &#61; optional&#40;object&#40;&#123;&#10;          host        &#61; optional&#40;string&#41;&#10;          path_prefix &#61; optional&#40;string&#41;&#10;        &#125;&#41;&#41;&#10;        weighted_backend_services &#61; optional&#40;map&#40;object&#40;&#123;&#10;          weight &#61; number&#10;          header_action &#61; optional&#40;object&#40;&#123;&#10;            request_add &#61; optional&#40;map&#40;object&#40;&#123;&#10;              value   &#61; string&#10;              replace &#61; optional&#40;bool, true&#41;&#10;            &#125;&#41;&#41;&#41;&#10;            request_remove &#61; optional&#40;list&#40;string&#41;&#41;&#10;            response_add &#61; optional&#40;map&#40;object&#40;&#123;&#10;              value   &#61; string&#10;              replace &#61; optional&#40;bool, true&#41;&#10;            &#125;&#41;&#41;&#41;&#10;            response_remove &#61; optional&#40;list&#40;string&#41;&#41;&#10;          &#125;&#41;&#41;&#10;        &#125;&#41;&#41;&#41;&#10;      &#125;&#41;&#41;&#10;      url_redirect &#61; optional&#40;object&#40;&#123;&#10;        host          &#61; optional&#40;string&#41;&#10;        https         &#61; optional&#40;bool&#41;&#10;        path          &#61; optional&#40;string&#41;&#10;        prefix        &#61; optional&#40;string&#41;&#10;        response_code &#61; optional&#40;string&#41;&#10;        strip_query   &#61; optional&#40;bool&#41;&#10;      &#125;&#41;&#41;&#10;    &#125;&#41;&#41;&#41;&#10;    route_rules &#61; optional&#40;list&#40;object&#40;&#123;&#10;      priority &#61; number&#10;      service  &#61; optional&#40;string&#41;&#10;      header_action &#61; optional&#40;object&#40;&#123;&#10;        request_add &#61; optional&#40;map&#40;object&#40;&#123;&#10;          value   &#61; string&#10;          replace &#61; optional&#40;bool, true&#41;&#10;        &#125;&#41;&#41;&#41;&#10;        request_remove &#61; optional&#40;list&#40;string&#41;&#41;&#10;        response_add &#61; optional&#40;map&#40;object&#40;&#123;&#10;          value   &#61; string&#10;          replace &#61; optional&#40;bool, true&#41;&#10;        &#125;&#41;&#41;&#41;&#10;        response_remove &#61; optional&#40;list&#40;string&#41;&#41;&#10;      &#125;&#41;&#41;&#10;      match_rules &#61; optional&#40;list&#40;object&#40;&#123;&#10;        ignore_case &#61; optional&#40;bool, false&#41;&#10;        headers &#61; optional&#40;list&#40;object&#40;&#123;&#10;          name         &#61; string&#10;          invert_match &#61; optional&#40;bool, false&#41;&#10;          type         &#61; optional&#40;string, &#34;present&#34;&#41; &#35; exact, prefix, suffix, regex, present, range, template&#10;          value        &#61; optional&#40;string&#41;&#10;          range_value &#61; optional&#40;object&#40;&#123;&#10;            end   &#61; string&#10;            start &#61; string&#10;          &#125;&#41;&#41;&#10;        &#125;&#41;&#41;&#41;&#10;        metadata_filters &#61; optional&#40;list&#40;object&#40;&#123;&#10;          labels    &#61; map&#40;string&#41;&#10;          match_all &#61; bool &#35; MATCH_ANY, MATCH_ALL&#10;        &#125;&#41;&#41;&#41;&#10;        path &#61; optional&#40;object&#40;&#123;&#10;          value &#61; string&#10;          type  &#61; optional&#40;string, &#34;prefix&#34;&#41; &#35; full, prefix, regex&#10;        &#125;&#41;&#41;&#10;        query_params &#61; optional&#40;list&#40;object&#40;&#123;&#10;          name  &#61; string&#10;          value &#61; string&#10;          type  &#61; optional&#40;string, &#34;present&#34;&#41; &#35; exact, present, regex&#10;        &#125;&#41;&#41;&#41;&#10;      &#125;&#41;&#41;&#41;&#10;      route_action &#61; optional&#40;object&#40;&#123;&#10;        request_mirror_backend &#61; optional&#40;string&#41;&#10;        cors_policy &#61; optional&#40;object&#40;&#123;&#10;          allow_credentials    &#61; optional&#40;bool&#41;&#10;          allow_headers        &#61; optional&#40;list&#40;string&#41;&#41;&#10;          allow_methods        &#61; optional&#40;list&#40;string&#41;&#41;&#10;          allow_origin_regexes &#61; optional&#40;list&#40;string&#41;&#41;&#10;          allow_origins        &#61; optional&#40;list&#40;string&#41;&#41;&#10;          disabled             &#61; optional&#40;bool&#41;&#10;          expose_headers       &#61; optional&#40;list&#40;string&#41;&#41;&#10;          max_age              &#61; optional&#40;string&#41;&#10;        &#125;&#41;&#41;&#10;        fault_injection_policy &#61; optional&#40;object&#40;&#123;&#10;          abort &#61; optional&#40;object&#40;&#123;&#10;            percentage &#61; number&#10;            status     &#61; number&#10;          &#125;&#41;&#41;&#10;          delay &#61; optional&#40;object&#40;&#123;&#10;            fixed &#61; object&#40;&#123;&#10;              seconds &#61; number&#10;              nanos   &#61; number&#10;            &#125;&#41;&#10;            percentage &#61; number&#10;          &#125;&#41;&#41;&#10;        &#125;&#41;&#41;&#10;        retry_policy &#61; optional&#40;object&#40;&#123;&#10;          num_retries      &#61; number&#10;          retry_conditions &#61; optional&#40;list&#40;string&#41;&#41;&#10;          per_try_timeout &#61; optional&#40;object&#40;&#123;&#10;            seconds &#61; number&#10;            nanos   &#61; optional&#40;number&#41;&#10;          &#125;&#41;&#41;&#10;        &#125;&#41;&#41;&#10;        timeout &#61; optional&#40;object&#40;&#123;&#10;          seconds &#61; number&#10;          nanos   &#61; optional&#40;number&#41;&#10;        &#125;&#41;&#41;&#10;        url_rewrite &#61; optional&#40;object&#40;&#123;&#10;          host          &#61; optional&#40;string&#41;&#10;          path_prefix   &#61; optional&#40;string&#41;&#10;          path_template &#61; optional&#40;string&#41;&#10;        &#125;&#41;&#41;&#10;        weighted_backend_services &#61; optional&#40;map&#40;object&#40;&#123;&#10;          weight &#61; number&#10;          header_action &#61; optional&#40;object&#40;&#123;&#10;            request_add &#61; optional&#40;map&#40;object&#40;&#123;&#10;              value   &#61; string&#10;              replace &#61; optional&#40;bool, true&#41;&#10;            &#125;&#41;&#41;&#41;&#10;            request_remove &#61; optional&#40;list&#40;string&#41;&#41;&#10;            response_add &#61; optional&#40;map&#40;object&#40;&#123;&#10;              value   &#61; string&#10;              replace &#61; optional&#40;bool, true&#41;&#10;            &#125;&#41;&#41;&#41;&#10;            response_remove &#61; optional&#40;list&#40;string&#41;&#41;&#10;          &#125;&#41;&#41;&#10;        &#125;&#41;&#41;&#41;&#10;      &#125;&#41;&#41;&#10;      url_redirect &#61; optional&#40;object&#40;&#123;&#10;        host          &#61; optional&#40;string&#41;&#10;        https         &#61; optional&#40;bool&#41;&#10;        path          &#61; optional&#40;string&#41;&#10;        prefix        &#61; optional&#40;string&#41;&#10;        response_code &#61; optional&#40;string&#41;&#10;        strip_query   &#61; optional&#40;bool&#41;&#10;      &#125;&#41;&#41;&#10;    &#125;&#41;&#41;&#41;&#10;    default_route_action &#61; optional&#40;object&#40;&#123;&#10;      weighted_backend_services &#61; optional&#40;map&#40;object&#40;&#123;&#10;        weight &#61; number&#10;        header_action &#61; optional&#40;object&#40;&#123;&#10;          request_add &#61; optional&#40;map&#40;object&#40;&#123;&#10;            value   &#61; string&#10;            replace &#61; optional&#40;bool, true&#41;&#10;          &#125;&#41;&#41;&#41;&#10;          request_remove &#61; optional&#40;list&#40;string&#41;&#41;&#10;          response_add &#61; optional&#40;map&#40;object&#40;&#123;&#10;            value   &#61; string&#10;            replace &#61; optional&#40;bool, true&#41;&#10;          &#125;&#41;&#41;&#41;&#10;          response_remove &#61; optional&#40;list&#40;string&#41;&#41;&#10;        &#125;&#41;&#41;&#10;      &#125;&#41;&#41;&#41;&#10;      url_rewrite &#61; optional&#40;object&#40;&#123;&#10;        host          &#61; optional&#40;string&#41;&#10;        path_prefix   &#61; optional&#40;string&#41;&#10;        path_template &#61; optional&#40;string&#41;&#10;      &#125;&#41;&#41;&#10;      timeout &#61; optional&#40;object&#40;&#123;&#10;        seconds &#61; number&#10;        nanos   &#61; optional&#40;number&#41;&#10;      &#125;&#41;&#41;&#10;      retry_policy &#61; optional&#40;object&#40;&#123;&#10;        num_retries      &#61; number&#10;        retry_conditions &#61; optional&#40;list&#40;string&#41;&#41;&#10;        per_try_timeout &#61; optional&#40;object&#40;&#123;&#10;          seconds &#61; number&#10;          nanos   &#61; optional&#40;number&#41;&#10;        &#125;&#41;&#41;&#10;      &#125;&#41;&#41;&#10;      request_mirror_backend &#61; optional&#40;string&#41;&#10;      cors_policy &#61; optional&#40;object&#40;&#123;&#10;        allow_credentials    &#61; optional&#40;bool&#41;&#10;        allow_headers        &#61; optional&#40;list&#40;string&#41;&#41;&#10;        allow_methods        &#61; optional&#40;list&#40;string&#41;&#41;&#10;        allow_origin_regexes &#61; optional&#40;list&#40;string&#41;&#41;&#10;        allow_origins        &#61; optional&#40;list&#40;string&#41;&#41;&#10;        disabled             &#61; optional&#40;bool&#41;&#10;        expose_headers       &#61; optional&#40;list&#40;string&#41;&#41;&#10;        max_age              &#61; optional&#40;string&#41;&#10;      &#125;&#41;&#41;&#10;      fault_injection_policy &#61; optional&#40;object&#40;&#123;&#10;        abort &#61; optional&#40;object&#40;&#123;&#10;          percentage &#61; number&#10;          status     &#61; number&#10;        &#125;&#41;&#41;&#10;        delay &#61; optional&#40;object&#40;&#123;&#10;          fixed &#61; object&#40;&#123;&#10;            seconds &#61; number&#10;            nanos   &#61; number&#10;          &#125;&#41;&#10;          percentage &#61; number&#10;        &#125;&#41;&#41;&#10;      &#125;&#41;&#41;&#10;    &#125;&#41;&#41;&#10;  &#125;&#41;&#41;&#41;&#10;  test &#61; optional&#40;list&#40;object&#40;&#123;&#10;    host        &#61; string&#10;    path        &#61; string&#10;    service     &#61; string&#10;    description &#61; optional&#40;string&#41;&#10;  &#125;&#41;&#41;&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code title="&#123;&#10;  default_service &#61; &#34;default&#34;&#10;&#125;">&#123;&#8230;&#125;</code> |

## Outputs

| name | description | sensitive |
|---|---|:---:|
| [address](outputs.tf#L17) | Forwarding rule address. |  |
| [backend_service_ids](outputs.tf#L22) | Backend service resources. |  |
| [backend_service_names](outputs.tf#L29) | Backend service resource names. |  |
| [forwarding_rule](outputs.tf#L36) | Forwarding rule resource. |  |
| [group_ids](outputs.tf#L41) | Autogenerated instance group ids. |  |
| [health_check_ids](outputs.tf#L48) | Autogenerated health check ids. |  |
| [id](outputs.tf#L55) | Fully qualified forwarding rule id. |  |
| [neg_ids](outputs.tf#L61) | Autogenerated network endpoint group ids. |  |
| [psc_neg_ids](outputs.tf#L68) | Autogenerated PSC network endpoint group ids. |  |
| [regional_neg_ids](outputs.tf#L75) | Autogenerated regional network endpoint group ids. |  |
| [service_attachment_id](outputs.tf#L82) | Id of the service attachment. |  |

## Fixtures

- [compute-vm-group-bc.tf](../../tests/fixtures/compute-vm-group-bc.tf)
<!-- END TFDOC -->
