variable "aiven_api_token" {
  type      = string
  sensitive = true
}

variable "project" {
  type = string
}

variable "cloud" {
  type    = string
  default = "google-europe-west1"
}

variable "plan" {
  type    = string
  default = "startup-4"
}

variable "source_service" {
  type    = string
  default = "pg-source-15"
}

variable "source_version" {
  type    = string
  default = "15"
}

variable "target_service" {
  type    = string
  default = "pg-target-18"
}

variable "target_version" {
  type    = string
  default = "18"
}

variable "dbname" {
  type    = string
  default = "shop"
}
