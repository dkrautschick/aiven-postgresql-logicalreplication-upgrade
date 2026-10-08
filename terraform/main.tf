# Terraform variant of scripts/01_create_services.sh: the two services and the demo database.
# Publications and subscriptions are SQL, not Aiven API objects, so they stay in scripts/sql.
# See terraform/README.md for the options you have there.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aiven = {
      source  = "aiven/aiven"
      version = ">= 4.0.0"
    }
  }
}

provider "aiven" {
  api_token = var.aiven_api_token
}

resource "aiven_pg" "source" {
  project                 = var.project
  cloud_name              = var.cloud
  plan                    = var.plan
  service_name            = var.source_service
  maintenance_window_dow  = "sunday"
  maintenance_window_time = "03:00:00"

  pg_user_config {
    pg_version = var.source_version
    # wal_level is logical on Aiven by default; nothing to set here.
  }
}

resource "aiven_pg" "target" {
  project                 = var.project
  cloud_name              = var.cloud
  plan                    = var.plan
  service_name            = var.target_service
  maintenance_window_dow  = "sunday"
  maintenance_window_time = "03:00:00"

  pg_user_config {
    pg_version = var.target_version
  }
}

resource "aiven_pg_database" "source_db" {
  project       = var.project
  service_name  = aiven_pg.source.service_name
  database_name = var.dbname
}

resource "aiven_pg_database" "target_db" {
  project       = var.project
  service_name  = aiven_pg.target.service_name
  database_name = var.dbname
}

output "source_uri" {
  value     = aiven_pg.source.service_uri
  sensitive = true
}

output "target_uri" {
  value     = aiven_pg.target.service_uri
  sensitive = true
}
