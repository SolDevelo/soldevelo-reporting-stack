# olmis-analytics-core

Reference **analytics-core** package for OpenLMIS/OLMIS. This is a permanent example that ships with the reporting-stack platform repository.

In production, each adopter maintains their own analytics-core package in a separate repository. This example demonstrates the expected structure and serves as a development/testing reference.

## Contents

| Directory | Purpose |
|---|---|
| `connect/` | Debezium connector JSON template for the OpenLMIS database |
| `dbt/` | dbt models, tests, and seeds for baseline OLMIS reporting marts |
| `superset/` | Superset assets-as-code (dashboards, charts, datasets) |

## Package contract

See the [package contract](../../README.md#package-contract) section in the platform README for the expected layout and loading mechanism.

## Usage

Set `ANALYTICS_CORE_PATH=examples/olmis-analytics-core` in the platform's `.env` (this is the default).
