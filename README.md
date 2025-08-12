# callisto-sandbox

<!-- prettier-ignore-start -->

<!-- toc -->

+ [Tech Stack](#tech-stack)
+ [Setup](#setup)
+ [Run Tests](#run-tests)
+ [Lint](#lint)

<!-- tocstop -->

<!-- prettier-ignore-end -->

## Tech Stack

- [Foundry](https://book.getfoundry.sh/) - A smart contract development toolchain.
- [Solhint](https://github.com/protofire/solhint) - To link Solidity code
- [slither](https://github.com/crytic/slither) - Static analyze for Solidity

## Setup

To set up the development environment, follow these steps:

1. Install [foundry](https://book.getfoundry.sh/getting-started/installation#using-foundryup)
1. Ensure you have [pnpm](https://pnpm.io/) installed.
1. Run the setup command to prepare the environment:

```shell
pnpm run setup
```

## Run Tests

To execute solidity tests:

```shell
forge test
```

## Lint

We use [pre-commit](https://pre-commit.com/) to lint the project

```shell
pnpm run lint
```

Lint process covering `solhint`, `forge fmt`, `forge test` and many other checks
