import hardhat from 'hardhat';

const { ethers } = hardhat;
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

async function main() {
  const [admin] = await ethers.getSigners();
  const delay = 0;

  const token = await ethers.deployContract('MockUSDC');
  await token.waitForDeployment();

  const profile = await ethers.deployContract('ProfileRegistry', [delay, admin.address]);
  await profile.waitForDeployment();

  const project = await ethers.deployContract('ProjectRegistry', [delay, admin.address]);
  await project.waitForDeployment();

  const escrow = await ethers.deployContract('MilestoneEscrow', [delay, admin.address]);
  await escrow.waitForDeployment();
  await (await escrow.allowToken(await token.getAddress())).wait();

  const license = await ethers.deployContract('LicenseRegistry', [await project.getAddress(), delay, admin.address]);
  await license.waitForDeployment();
  await (await project.setLicenseRegistry(await license.getAddress())).wait();

  const reputation = await ethers.deployContract('ReputationAttestation', [delay, admin.address]);
  await reputation.waitForDeployment();
  const referral = await ethers.deployContract('ReferralRegistry', [delay, admin.address]);
  await referral.waitForDeployment();

  const deployment = {
    network: 'hardhat-local',
    chainId: 31337,
    deployer: admin.address,
    MockUSDC: await token.getAddress(),
    ProfileRegistry: await profile.getAddress(),
    ProjectRegistry: await project.getAddress(),
    MilestoneEscrow: await escrow.getAddress(),
    LicenseRegistry: await license.getAddress(),
    ReputationAttestation: await reputation.getAddress(),
    ReferralRegistry: await referral.getAddress(),
  };

  const outputDir = join(process.cwd(), 'web3-linkedin-frontend', 'src', 'contracts');
  mkdirSync(outputDir, { recursive: true });
  writeFileSync(join(outputDir, 'local-deployment.json'), `${JSON.stringify(deployment, null, 2)}\n`);
  console.log(JSON.stringify(deployment, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
