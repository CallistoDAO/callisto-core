# Callisto Core

## Setup

Prerequisites: install [Foundry](https://book.getfoundry.sh/getting-started/installation#using-foundryup).

To automatically install all the dependencies, run the command:

```shell
forge soldeer install --clean && forge soldeer update
```

## Commands

1. To run all the tests, use:

   ```shell
   forge t
   ```

2. To run all the tests and generate a code coverage report with a summary:

   ```shell
   forge coverage --nmco='test/|script/' --ir-minimum --report lcov --report summary
   ```

## Documentation

- [Emergency Redemption Flow](./docs/emergency_redemption_flow.md).
