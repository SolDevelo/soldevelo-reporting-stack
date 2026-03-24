# Contributing to SolDevelo Reporting Stack

Thank you for your interest in contributing to the SolDevelo Reporting Stack.

## Workflow

1. Fork the repository and create a feature branch from `main`.
2. Make your changes in small, focused commits.
3. Ensure all linting and verification targets pass: `make lint verify`.
4. Open a pull request against `main` with a clear description of the change.

## Code standards

- Follow the `.editorconfig` settings for formatting.
- SQL (ClickHouse init scripts, dbt models): lowercase keywords, 2-space indent.
- Python (Airflow DAGs, scripts): follow PEP 8, 4-space indent.
- YAML: 2-space indent, no trailing whitespace.

## Commit messages

Use short, imperative-mood subject lines (e.g. "Add raw landing schema for requisitions"). Include a body when context is needed.

## Reporting issues

Open a GitHub issue with:
- Steps to reproduce
- Expected vs. actual behavior
- Relevant logs or screenshots

## License

By contributing you agree that your contributions will be licensed under the AGPL-3.0 license (see `LICENSE`).
