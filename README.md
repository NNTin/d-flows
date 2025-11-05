# d-flows

[![Version](https://img.shields.io/github/v/release/nntin/d-flows?sort=semver&label=Version)](https://github.com/nntin/d-flows/releases) [![CI](https://img.shields.io/github/actions/workflow/status/nntin/d-flows/pr-ci.yml?branch=main&label=CI)](https://github.com/nntin/d-flows/actions)

## Documentation

- [README.md](./README.md) - Overview and quick start
- [VERSIONING.md](./VERSIONING.md) - Version management strategy and workflows
- [ACT_SETUP_GUIDE.md](./ACT_SETUP_GUIDE.md) - Setup for local testing with act
- [ACT_USAGE.md](./ACT_USAGE.md) - Unit testing guide and examples
- [INTEGRATION_TESTING.md](./INTEGRATION_TESTING.md) - Multi-workflow integration testing guide

## Testing

The repository includes comprehensive testing infrastructure:

### Unit Tests
Test individual workflows with specific inputs using [act](https://github.com/nektos/act):
- See [ACT_USAGE.md](./ACT_USAGE.md) for unit testing guide
- Test fixtures in `tests/bump-version/`, `tests/release/`, `tests/discord-notify/`, `tests/step-summary/`

### Integration Tests
Test complete release cycles and multi-workflow scenarios:
- See [INTEGRATION_TESTING.md](./INTEGRATION_TESTING.md) for integration testing guide
- Test scenarios in `tests/integration/`
- Run with `./run-integration-tests.ps1`

### Quick Start Testing

```powershell
# Verify act setup
.\verify-act-setup.ps1

# Run a unit test
act workflow_dispatch -W .github/workflows/bump-version.yml -e tests/bump-version/first-release-main.json

# Run all integration tests
.\run-integration-tests.ps1
```