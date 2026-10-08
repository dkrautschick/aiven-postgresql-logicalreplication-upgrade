# Terraform notes

`terraform apply` here replaces `scripts/01_create_services.sh`. Everything after that
(schema copy, publication, subscription, checks, cutover) is SQL and stays in `scripts/`
and `sql/`, because the Aiven API has no notion of publications or subscriptions.

```bash
cd terraform
export TF_VAR_aiven_api_token=$(avn user access-token create --description terraform-demo --json | jq -r .full_token)
terraform init
terraform apply -var project=my-aiven-project
```

Then continue with `../scripts/02_schema_and_seed.sh` (the scripts read connection
details from the Aiven API, so they work regardless of how the services were created).

## Want the SQL in Terraform too?

Two realistic options:

1. **`null_resource` + `local-exec`** that runs `psql -f` against `aiven_pg.*.service_uri`
   after the services exist. Simple, honest, and it is what most teams end up doing.
2. **The `cyrilgdn/postgresql` provider**, which has `postgresql_publication` and
   `postgresql_subscription` resources. The publication resource works on the Aiven
   source for explicit table lists (`FOR ALL TABLES` needs superuser, which Aiven does not
   hand out). The subscription resource runs `CREATE SUBSCRIPTION` directly and that
   needs superuser as well, so on the Aiven target you still need
   `aiven_extras.pg_create_subscription()` via option 1.

Either way: keep the cutover (read-only switch, sequence sync, ANALYZE) as a script you run
by hand. A cutover is a decision, not a `terraform apply`.

## In-place upgrade for comparison

If you only want to test Aiven's one-step in-place upgrade (pg_upgrade under the hood,
short downtime, no rollback), change `source_version` from `"15"` to `"18"` and apply.
Terraform calls the same API as `avn service update -c pg_version=18`.
