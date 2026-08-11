import { ethers } from 'hardhat';
import { writeFileSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';

async function main() {
  const escrow = await ethers.deployContract('LocalWeb3LinkedInEscrow');
  await escrow.waitForDeployment();
  const address = await escrow.getAddress();
  console.log(`LocalWeb3LinkedInEscrow deployed to ${address}`);

  // Wire the address straight into the frontend so you don't have to hand-copy it.
  const network = (await ethers.provider.getNetwork()).name;
  const isLocal = network === 'localhost' || network === 'hardhat';
  if (isLocal) {
    const envPath = join(__dirname, '..', '..', '..', 'artifacts', 'web3-linkedin', '.env');
    const existing = existsSync(envPath) ? readFileSync(envPath, 'utf8') : '';
    const withoutOldAddress = existing.split('\n').filter((line) => !line.startsWith('VITE_ESCROW_ADDRESS=')).join('\n');
    const next = `${withoutOldAddress.trim()}\nVITE_ESCROW_ADDRESS=${address}\n`;
    writeFileSync(envPath, next.replace(/^\n+/, ''));
    console.log(`Wrote VITE_ESCROW_ADDRESS to ${envPath}`);
    console.log('Restart the frontend dev server so Vite picks up the new env value.');
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

// import { ethers } from 'hardhat';

// async function main() {
//   const escrow = await ethers.deployContract('LocalWeb3LinkedInEscrow');
//   await escrow.waitForDeployment();
//   console.log(`LocalWeb3LinkedInEscrow deployed to ${await escrow.getAddress()}`);
// }

// main().catch((error) => {
//   console.error(error);
//   process.exitCode = 1;
// });