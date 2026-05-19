# outreach-schema

Database schema and migrations for the PlotLens outreach pipeline. Single Postgres database `outreach` on LXC 114.

## Apply migrations

```bash
cp dbmate.env.example .env
# edit .env to set DATABASE_URL pointing at LXC 114 outreach DB
make migrate
```

## Roll back the last migration

```bash
make rollback
```

## Run trigger-enforcement tests

```bash
make test
```

See the spec at `docs/superpowers/specs/2026-05-19-plotlens-outreach-stack-design.md` for the schema design and the safety rationale behind the `publish_jobs` enforcement trigger.
