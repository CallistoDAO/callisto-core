import { Command } from "commander";
import { execa } from "execa";
import fse from "fs-extra/esm";
import fs from "fs/promises";
import path from "path";
import { format } from "prettier";

const env = { ...process.env, NX_VERBOSE_LOGGING: "true" };
const $$ = execa({ env, verbose: "full" });
const $ = execa({ env, verbose: "short" });

const program = new Command();

const checkCommand = async (commandName: string): Promise<void> => {
  try {
    await $$`which ${commandName}`;
  } catch {
    console.error(`Command [${commandName}] is not available. Please install it.`);
    process.exit(1);
  }
};

const scanForContracts = async (dir: string): Promise<string[]> => {
  const contracts: string[] = [];

  const scanDirectory = async (dirPath: string): Promise<void> => {
    const entries = await fs.readdir(dirPath, { withFileTypes: true });

    for (const entry of entries) {
      const fullPath = path.join(dirPath, entry.name);

      if (entry.isDirectory()) {
        await scanDirectory(fullPath);
      } else if (entry.isFile() && entry.name.endsWith(".sol")) {
        const content = await fs.readFile(fullPath, "utf8");
        const relativePath = path.relative("src", fullPath);
        const contractName = path.basename(entry.name, ".sol");

        // Skip if it's an abstract contract
        if (content.includes("abstract contract") || content.includes("library ")) {
          continue;
        }

        // Check if it contains interface or contract definition
        const interfaceMatch = content.match(/interface\s+(\w+)/);
        const contractMatch = content.match(/contract\s+(\w+)/);

        if (interfaceMatch || contractMatch) {
          // Use the format: src/path/to/file.sol:ContractName
          const contractPath = `src/${relativePath}:${contractName}`;
          contracts.push(contractPath);
        }
      }
    }
  };

  await scanDirectory(dir);
  return contracts;
};

const coverage = async (ci: boolean): Promise<void> => {
  console.log("Running coverage...");
  await checkCommand("lcov");
  await $`forge coverage --no-match-coverage=test/|script/ --ir-minimum --report lcov --report summary ${ci ? ' --nmc "CallistoVaultTenderlyEthereumTests|OlympusBehaviorResearchTenderlyEthereumTests"' : ""}`;
  // await $`lcov --output-file lcov.info --ignore-errors inconsistent,inconsistent,mismatch,mismatch,unused,unused --remove lcov.info "test/**/" --remove lcov.info "scripts/**/"`;
  await $`genhtml --output-directory coverage --ignore-errors unmapped,category lcov.info`;
};

program.action(async () => {
  console.log("Running init...");

  // Verify environment
  console.log("Running setup...");
  // Verify environment
  await checkCommand("forge");
  await checkCommand("jq");
  await $`pnpm husky`;
  await $`forge soldeer install --clean`;
  await $`forge soldeer update`;
  fse.removeSync("lib/");
  fse.removeSync("dependencies/@openzeppelin-contracts-5.0.2/");
  fse.removeSync("dependencies/@layerzerolabs-oft-evm-3.1.3/");
  fse.removeSync("dependencies/solidity-examples-1.1.1/");
  fse.removeSync("dependencies/@openzeppelin-contracts-5.3.0-rc.0/");

  // await $`pip3 install slither-analyzer`;

  console.log("Setup complete!");
});

program.command("generate-abi").action(async () => {
  console.log("Running generate-abi...");
  fse.mkdirsSync("./abis");

  console.log("Scanning for contracts and interfaces...");
  const contracts = await scanForContracts("src");
  console.log(`Found ${contracts.length} contracts/interfaces:`);
  contracts.forEach((contract) => console.log(`  - ${contract}`));

  // Get expected contract names from discovered contracts
  const expectedContractNames = new Set(
    contracts.map((contract) => {
      const contractName = contract.split(":")[1] || contract.split("/").pop()?.replace(".sol", "");
      return `${contractName}.json`;
    }),
  );

  // Clean up orphaned JSON files
  try {
    const existingFiles = await fs.readdir("./abis");
    const jsonFiles = existingFiles.filter((file) => file.endsWith(".json"));

    for (const file of jsonFiles) {
      if (!expectedContractNames.has(file)) {
        await fs.unlink(`./abis/${file}`);
        console.log(`Removed orphaned ABI file: ${file}`);
      }
    }
  } catch (error) {
    // Ignore error if abis directory doesn't exist or is empty
  }

  await Promise.all(
    contracts.map(async (contract) => {
      try {
        const { stdout } = await $`forge inspect ${contract} abi --json`;
        const contractName = contract.split(":")[1] || contract.split("/").pop()?.replace(".sol", "");
        // Format the JSON output with Prettier before writing
        const formattedJson = await format(stdout, { parser: "json" });
        await fs.writeFile(`./abis/${contractName}.json`, formattedJson);
        console.log(`Generated ABI for ${contractName}`);
      } catch (error) {
        console.error(`Failed to generate ABI for ${contract}:`, error);
      }
    }),
  );
  console.log("ABI generation complete!");
});

program.command("coverage").action(async () => {
  await coverage(false);
});

program.command("coverage-ci").action(async () => {
  await coverage(true);
});

await program.parseAsync(process.argv);
