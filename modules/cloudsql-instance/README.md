# Cloud SQL instance module

This module manages the creation of Cloud SQL instances with potential read replicas in other regions. It can also create an initial set of users and databases via the `users` and `databases` parameters.

Note that this module assumes that some options are the same for both the primary instance and all the replicas (e.g. tier, disks, labels, flags, etc).

*Warning:* if you use the `users` field, you terraform state will contain each user's password in plain text.

<!-- BEGIN TOC -->
- [Examples](#examples)
  - [Simple example](#simple-example)
  - [Cross-regional read replica](#cross-regional-read-replica)
  - [Custom flags, databases and users](#custom-flags-databases-and-users)
  - [CMEK encryption](#cmek-encryption)
  - [Instance with PSC enabled](#instance-with-psc-enabled)
  - [Enable public IP](#enable-public-ip)
  - [Query Insights](#query-insights)
  - [Maintenance Config](#maintenance-config)
  - [SSL Config](#ssl-config)
  - [Password Validation Policy and Root Password Config](#password-validation-policy-and-root-password-config)
- [Variables](#variables)
- [Outputs](#outputs)
- [Fixtures](#fixtures)
<!-- END TOC -->

## Examples

### Simple example

This example shows how to setup a project, VPC and a standalone Cloud SQL instance.

```hcl
module "project" {
  source          = "./fabric/modules/project"
  billing_account = var.billing_account_id
  parent          = var.folder_id
  name            = "db-prj"
  prefix          = var.prefix
  services = [
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
  ]
}

module "vpc" {
  source     = "./fabric/modules/net-vpc"
  project_id = module.project.project_id
  name       = "my-network"
  # need only one - psa_config or subnets_psc
  psa_configs = [{
    ranges          = { cloud-sql = "10.60.0.0/16" }
    deletion_policy = "ABANDON"
  }]
  subnets_psc = [
    {
      ip_cidr_range = "10.0.3.0/24"
      name          = "psc"
      region        = var.region
    }
  ]
}

module "db" {
  source     = "./fabric/modules/cloudsql-instance"
  project_id = module.project.project_id
  network_config = {
    connectivity = {
      psa_config = {
        private_network = module.vpc.self_link
      }
      # psc_allowed_consumer_projects = [var.project_id]
    }
  }
  name                          = "db"
  region                        = var.region
  database_version              = "POSTGRES_13"
  tier                          = "db-g1-small"
  gcp_deletion_protection       = false
  terraform_deletion_protection = false
}
# tftest modules=3 resources=16 inventory=simple.yaml isolated e2e
```

### Cross-regional read replica

```hcl
module "db" {
  source     = "./fabric/modules/cloudsql-instance"
  project_id = var.project_id
  network_config = {
    connectivity = {
      psa_config = {
        private_network = var.vpc.self_link
      }
    }
  }
  name             = "db"
  prefix           = "myprefix"
  region           = var.region
  database_version = "POSTGRES_16"
  tier             = "db-g1-small"

  replicas = {
    replica1 = { region = "europe-west3" }
    replica2 = { region = "us-central1" }
  }
  gcp_deletion_protection       = false
  terraform_deletion_protection = false
}
# tftest modules=1 resources=3 inventory=replicas.yaml e2e
```

### Custom flags, databases and users

```hcl
module "db" {
  source     = "./fabric/modules/cloudsql-instance"
  project_id = var.project_id
  network_config = {
    connectivity = {
      psa_config = {
        private_network = var.vpc.self_link
      }
    }
  }
  name             = "db"
  region           = var.region
  database_version = "MYSQL_8_0"
  tier             = "db-g1-small"

  flags = {
    cloudsql_iam_authentication    = "on"
    disconnect_on_expired_password = "on"
  }

  databases = [
    "people",
    "departments"
  ]

  users = {
    # generatea password for user1
    user1 = {
      password = null
    }
    # assign a password to user2
    user2 = {
      password = "mypassword"
    }
    # IAM Service Account
    (module.iam-service-account.email) = {
      type = "CLOUD_IAM_SERVICE_ACCOUNT"
    }
  }
  gcp_deletion_protection       = false
  terraform_deletion_protection = false
}
# tftest fixtures=fixtures/iam-service-account.tf inventory=custom.yaml e2e
```

### CMEK encryption

```hcl
module "project" {
  source          = "./fabric/modules/project"
  name            = "cloudsql"
  billing_account = var.billing_account_id
  prefix          = var.prefix
  parent          = var.folder_id
  services = [
    "cloudkms.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
  ]
}

module "kms" {
  source     = "./fabric/modules/kms"
  project_id = module.project.project_id
  keyring = {
    location = var.region
    name     = "${var.prefix}-keyring"
  }
  keys = {
    "key-regional" = {
    }
  }
  iam = {
    "roles/cloudkms.cryptoKeyEncrypterDecrypter" = [
      module.project.service_agents["cloud-sql"].iam_email
    ]
  }
}

module "vpc" {
  source     = "./fabric/modules/net-vpc"
  project_id = module.project.project_id
  name       = "my-network"
  subnets = [
    {
      ip_cidr_range = "10.0.0.0/24"
      name          = "production"
      region        = var.region
    },
  ]
  psa_configs = [{
    ranges          = { myrange = "10.0.1.0/24" }
    deletion_policy = "ABANDON"
  }]
}


module "db" {
  source              = "./fabric/modules/cloudsql-instance"
  project_id          = module.project.project_id
  encryption_key_name = module.kms.keys.key-regional.id
  network_config = {
    connectivity = {
      psa_config = {
        private_network = module.vpc.self_link
      }
    }
  }
  name                          = "db"
  region                        = var.region
  database_version              = "POSTGRES_13"
  tier                          = "db-g1-small"
  gcp_deletion_protection       = false
  terraform_deletion_protection = false
}

# tftest modules=4 resources=22 isolated e2e
```

### Instance with PSC enabled

```hcl
module "db" {
  source     = "./fabric/modules/cloudsql-instance"
  project_id = var.project_id
  network_config = {
    connectivity = {
      psc_allowed_consumer_projects = [var.project_id]
    }
  }
  prefix            = "myprefix"
  name              = "db"
  region            = var.region
  availability_type = "REGIONAL"
  database_version  = "POSTGRES_13"
  tier              = "db-g1-small"

  gcp_deletion_protection       = false
  terraform_deletion_protection = false
}
# tftest modules=1 resources=1 inventory=psc.yaml e2e
```

### Enable public IP

Use `public_ipv4` to create instances with a public IP.

```hcl
module "db" {
  source     = "./fabric/modules/cloudsql-instance"
  project_id = var.project_id
  network_config = {
    connectivity = {
      public_ipv4 = true
      psa_config = {
        private_network = var.vpc.self_link
      }
    }
  }
  name                          = "db"
  region                        = var.region
  tier                          = "db-g1-small"
  database_version              = "MYSQL_8_0"
  gcp_deletion_protection       = false
  terraform_deletion_protection = false
}
# tftest modules=1 resources=1 inventory=public-ip.yaml e2e
```

### Query Insights

Provide `insights_config` (can be just empty `{}`) to enable [Query Insights](https://cloud.google.com/sql/docs/postgres/using-query-insights)

```hcl
module "db" {
  source     = "./fabric/modules/cloudsql-instance"
  project_id = var.project_id
  network_config = {
    connectivity = {
      psa_config = {
        private_network = var.vpc.self_link
      }
    }
  }
  name             = "db"
  region           = var.region
  database_version = "POSTGRES_13"
  tier             = "db-g1-small"

  insights_config = {
    query_string_length = 2048
  }
  gcp_deletion_protection       = false
  terraform_deletion_protection = false
}
# tftest modules=1 resources=1 inventory=insights.yaml e2e
```

### Maintenance Config

Provide `maintenance_config` (can be just empty `{}`) to enable [Maintenance](https://cloud.google.com/sql/docs/postgres/maintenance)

```hcl
module "db" {
  source     = "./fabric/modules/cloudsql-instance"
  project_id = var.project_id
  network_config = {
    connectivity = {
      psa_config = {
        private_network = var.vpc.self_link
      }
    }
  }
  name             = "db"
  region           = var.region
  database_version = "POSTGRES_13"
  tier             = "db-g1-small"

  maintenance_config            = {}
  gcp_deletion_protection       = false
  terraform_deletion_protection = false
}
# tftest modules=1 resources=1 e2e
```

### SSL Config

Provide `ssl` (can be just empty `{}`) to enable [SSL](https://cloud.google.com/sql/docs/postgres/configure-ssl-instance)

```hcl
module "db" {
  source     = "./fabric/modules/cloudsql-instance"
  project_id = var.project_id
  network_config = {
    connectivity = {
      psa_config = {
        private_network = var.vpc.self_link
      }
    }
  }
  name             = "db"
  region           = var.region
  database_version = "POSTGRES_13"
  tier             = "db-g1-small"

  ssl                           = {}
  gcp_deletion_protection       = false
  terraform_deletion_protection = false
}
# tftest modules=1 resources=1 e2e
```

### Password Validation Policy and Root Password Config

Provide parameters to configure `password_validation_policy` if required.  The `root_password` can also be provided: either an explicit password OR a flag to enable a randomly-generated password.

```hcl
module "db" {
  source     = "./fabric/modules/cloudsql-instance"
  project_id = var.project_id
  network_config = {
    connectivity = {
      psa_config = {
        private_network = var.vpc.self_link
      }
    }
  }
  name             = "db"
  region           = var.region
  database_version = "MYSQL_8_0"
  tier             = "db-g1-small"

  gcp_deletion_protection       = false
  terraform_deletion_protection = false

  root_password = {
    # password = "ExplitPassword123!"
    random_password = true
  }

  password_validation_policy = {
    enabled                     = true
    default_complexity          = true
    disallow_username_substring = true
    min_length                  = 20
    reuse_interval              = 5
  }
}
# tftest modules=1 resources=2 e2e
```
<!-- BEGIN TFDOC -->
## Variables

| name | description | type | required | default |
|---|---|:---:|:---:|:---:|
| [database_version](variables.tf#L75) | Database type and version to create. | <code>string</code> | ✓ |  |
| [name](variables.tf#L179) | Name of primary instance. | <code>string</code> | ✓ |  |
| [network_config](variables.tf#L184) | Network configuration for the instance. Only one between private_network and psc_config can be used. | <code title="object&#40;&#123;&#10;  authorized_networks &#61; optional&#40;map&#40;string&#41;&#41;&#10;  connectivity &#61; object&#40;&#123;&#10;    public_ipv4 &#61; optional&#40;bool, false&#41;&#10;    psa_config &#61; optional&#40;object&#40;&#123;&#10;      private_network &#61; string&#10;      allocated_ip_ranges &#61; optional&#40;object&#40;&#123;&#10;        primary &#61; optional&#40;string&#41;&#10;        replica &#61; optional&#40;string&#41;&#10;      &#125;&#41;&#41;&#10;    &#125;&#41;&#41;&#10;    psc_allowed_consumer_projects    &#61; optional&#40;list&#40;string&#41;&#41;&#10;    enable_private_path_for_services &#61; optional&#40;bool, false&#41;&#10;  &#125;&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> | ✓ |  |
| [project_id](variables.tf#L231) | The ID of the project where this instances will be created. | <code>string</code> | ✓ |  |
| [region](variables.tf#L236) | Region of the primary instance. | <code>string</code> | ✓ |  |
| [tier](variables.tf#L288) | The machine type to use for the instances. | <code>string</code> | ✓ |  |
| [activation_policy](variables.tf#L16) | This variable specifies when the instance should be active. Can be either ALWAYS, NEVER or ON_DEMAND. Default is ALWAYS. | <code>string</code> |  | <code>&#34;ALWAYS&#34;</code> |
| [availability_type](variables.tf#L27) | Availability type for the primary replica. Either `ZONAL` or `REGIONAL`. | <code>string</code> |  | <code>&#34;ZONAL&#34;</code> |
| [backup_configuration](variables.tf#L33) | Backup settings for primary instance. Will be automatically enabled if using MySQL with one or more replicas. | <code title="object&#40;&#123;&#10;  enabled                        &#61; optional&#40;bool, false&#41;&#10;  binary_log_enabled             &#61; optional&#40;bool, false&#41;&#10;  start_time                     &#61; optional&#40;string, &#34;23:00&#34;&#41;&#10;  location                       &#61; optional&#40;string&#41;&#10;  log_retention_days             &#61; optional&#40;number, 7&#41;&#10;  point_in_time_recovery_enabled &#61; optional&#40;bool&#41;&#10;  retention_count                &#61; optional&#40;number, 7&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code title="&#123;&#10;  enabled                        &#61; false&#10;  binary_log_enabled             &#61; false&#10;  start_time                     &#61; &#34;23:00&#34;&#10;  location                       &#61; null&#10;  log_retention_days             &#61; 7&#10;  point_in_time_recovery_enabled &#61; null&#10;  retention_count                &#61; 7&#10;&#125;">&#123;&#8230;&#125;</code> |
| [collation](variables.tf#L56) | The name of server instance collation. | <code>string</code> |  | <code>null</code> |
| [connector_enforcement](variables.tf#L62) | Specifies if connections must use Cloud SQL connectors. | <code>string</code> |  | <code>null</code> |
| [data_cache](variables.tf#L68) | Enable data cache. Only used for Enterprise MYSQL and PostgreSQL. | <code>bool</code> |  | <code>false</code> |
| [databases](variables.tf#L80) | Databases to create once the primary instance is created. | <code>list&#40;string&#41;</code> |  | <code>null</code> |
| [disk_autoresize_limit](variables.tf#L86) | The maximum size to which storage capacity can be automatically increased. The default value is 0, which specifies that there is no limit. | <code>number</code> |  | <code>0</code> |
| [disk_size](variables.tf#L92) | Disk size in GB. Set to null to enable autoresize. | <code>number</code> |  | <code>null</code> |
| [disk_type](variables.tf#L98) | The type of data disk: `PD_SSD` or `PD_HDD`. | <code>string</code> |  | <code>&#34;PD_SSD&#34;</code> |
| [edition](variables.tf#L104) | The edition of the instance, can be ENTERPRISE or ENTERPRISE_PLUS. | <code>string</code> |  | <code>&#34;ENTERPRISE&#34;</code> |
| [encryption_key_name](variables.tf#L110) | The full path to the encryption key used for the CMEK disk encryption of the primary instance. | <code>string</code> |  | <code>null</code> |
| [flags](variables.tf#L116) | Map FLAG_NAME=>VALUE for database-specific tuning. | <code>map&#40;string&#41;</code> |  | <code>null</code> |
| [gcp_deletion_protection](variables.tf#L122) | Set Google's deletion protection attribute which applies across all surfaces (UI, API, & Terraform). | <code>bool</code> |  | <code>true</code> |
| [insights_config](variables.tf#L129) | Query Insights configuration. Defaults to null which disables Query Insights. | <code title="object&#40;&#123;&#10;  query_string_length     &#61; optional&#40;number, 1024&#41;&#10;  record_application_tags &#61; optional&#40;bool, false&#41;&#10;  record_client_address   &#61; optional&#40;bool, false&#41;&#10;  query_plans_per_minute  &#61; optional&#40;number, 5&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code>null</code> |
| [labels](variables.tf#L140) | Labels to be attached to all instances. | <code>map&#40;string&#41;</code> |  | <code>null</code> |
| [maintenance_config](variables.tf#L146) | Set maintenance window configuration and maintenance deny period (up to 90 days). Date format: 'yyyy-mm-dd'. | <code title="object&#40;&#123;&#10;  maintenance_window &#61; optional&#40;object&#40;&#123;&#10;    day          &#61; number&#10;    hour         &#61; number&#10;    update_track &#61; optional&#40;string, null&#41;&#10;  &#125;&#41;, null&#41;&#10;  deny_maintenance_period &#61; optional&#40;object&#40;&#123;&#10;    start_date &#61; string&#10;    end_date   &#61; string&#10;    start_time &#61; optional&#40;string, &#34;00:00:00&#34;&#41;&#10;  &#125;&#41;, null&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code>&#123;&#125;</code> |
| [password_validation_policy](variables.tf#L207) | Password validation policy configuration for instances. | <code title="object&#40;&#123;&#10;  enabled &#61; optional&#40;bool, true&#41;&#10;  change_interval             &#61; optional&#40;number&#41;&#10;  default_complexity          &#61; optional&#40;bool&#41;&#10;  disallow_username_substring &#61; optional&#40;bool&#41;&#10;  min_length                  &#61; optional&#40;number&#41;&#10;  reuse_interval              &#61; optional&#40;number&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code>null</code> |
| [prefix](variables.tf#L221) | Optional prefix used to generate instance names. | <code>string</code> |  | <code>null</code> |
| [replicas](variables.tf#L241) | Map of NAME=> {REGION, KMS_KEY, AVAILABILITY_TYPE} for additional read replicas. Set to null to disable replica creation. | <code title="map&#40;object&#40;&#123;&#10;  region              &#61; string&#10;  encryption_key_name &#61; optional&#40;string&#41;&#10;  availability_type   &#61; optional&#40;string&#41;&#10;&#125;&#41;&#41;">map&#40;object&#40;&#123;&#8230;&#125;&#41;&#41;</code> |  | <code>&#123;&#125;</code> |
| [root_password](variables.tf#L252) | Root password of the Cloud SQL instance, or flag to create a random password. Required for MS SQL Server. | <code title="object&#40;&#123;&#10;  password        &#61; optional&#40;string&#41;&#10;  random_password &#61; optional&#40;bool, false&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code>&#123;&#125;</code> |
| [ssl](variables.tf#L266) | Setting to enable SSL, set config and certificates. | <code title="object&#40;&#123;&#10;  client_certificates &#61; optional&#40;list&#40;string&#41;&#41;&#10;  mode &#61; optional&#40;string&#41;&#10;&#125;&#41;">object&#40;&#123;&#8230;&#125;&#41;</code> |  | <code>&#123;&#125;</code> |
| [terraform_deletion_protection](variables.tf#L281) | Prevent terraform from deleting instances. | <code>bool</code> |  | <code>true</code> |
| [time_zone](variables.tf#L293) | The time_zone to be used by the database engine (supported only for SQL Server), in SQL Server timezone format. | <code>string</code> |  | <code>null</code> |
| [users](variables.tf#L299) | Map of users to create in the primary instance (and replicated to other replicas). For MySQL, anything after the first `@` (if present) will be used as the user's host. Set PASSWORD to null if you want to get an autogenerated password. The user types available are: 'BUILT_IN', 'CLOUD_IAM_USER' or 'CLOUD_IAM_SERVICE_ACCOUNT'. | <code title="map&#40;object&#40;&#123;&#10;  password         &#61; optional&#40;string&#41;&#10;  password_version &#61; optional&#40;number&#41;&#10;  type             &#61; optional&#40;string, &#34;BUILT_IN&#34;&#41;&#10;&#125;&#41;&#41;">map&#40;object&#40;&#123;&#8230;&#125;&#41;&#41;</code> |  | <code>&#123;&#125;</code> |

## Outputs

| name | description | sensitive |
|---|---|:---:|
| [client_certificates](outputs.tf#L24) | The CA Certificate used to connect to the SQL Instance via SSL. | ✓ |
| [connection_name](outputs.tf#L30) | Connection name of the primary instance. |  |
| [connection_names](outputs.tf#L35) | Connection names of all instances. |  |
| [dns_name](outputs.tf#L43) | The dns name of the instance. |  |
| [dns_names](outputs.tf#L48) | Dns names of all instances. |  |
| [id](outputs.tf#L56) | Fully qualified primary instance id. |  |
| [ids](outputs.tf#L61) | Fully qualified ids of all instances. |  |
| [instances](outputs.tf#L69) | Cloud SQL instance resources. | ✓ |
| [ip](outputs.tf#L75) | IP address of the primary instance. |  |
| [ips](outputs.tf#L80) | IP addresses of all instances. |  |
| [name](outputs.tf#L88) | Name of the primary instance. |  |
| [names](outputs.tf#L93) | Names of all instances. |  |
| [psc_service_attachment_link](outputs.tf#L101) | The link to service attachment of PSC instance. |  |
| [psc_service_attachment_links](outputs.tf#L106) | Links to service attachment of PSC instances. |  |
| [self_link](outputs.tf#L114) | Self link of the primary instance. |  |
| [self_links](outputs.tf#L119) | Self links of all instances. |  |
| [user_passwords](outputs.tf#L127) | Map of containing the password of all users created through terraform. | ✓ |

## Fixtures

- [iam-service-account.tf](../../tests/fixtures/iam-service-account.tf)
<!-- END TFDOC -->
