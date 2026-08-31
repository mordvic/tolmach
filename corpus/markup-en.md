# Deployment guide

This section explains how the **staging** environment differs from *production*, and why the `deploy.sh` script refuses to run on Fridays.

## Requirements

Before you start, make sure that:

- the **API token** is present in the vault
- the *read-only* replica is healthy
  - its lag is below `500ms`
- the backup finished

1. Stop the ingest workers.
2. Run the migration with **exactly one** retry.
3. Restart the workers and *watch the queue*.

> Never skip the second step: a failed migration leaves the schema **half-updated**, and the workers will crash on the *first* message.

| Environment | Replicas | Auto-deploy |
|---|---|---|
| staging | 2 | **yes** |
| production | 6 | *no* |

The table above is updated **manually** after every release.
