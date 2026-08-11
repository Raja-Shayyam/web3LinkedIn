import { expect } from 'chai';
import { ethers } from 'hardhat';

describe('LocalWeb3LinkedInEscrow', () => {
  it('runs the complete hire, proof, approval and release lifecycle once', async () => {
    const [developer, recruiter] = await ethers.getSigners();
    const escrow = await ethers.deployContract('LocalWeb3LinkedInEscrow');
    const amount = ethers.parseEther('1');

    await escrow.connect(developer).createMilestone('Ship the public beta', amount);
    await escrow.connect(recruiter).hire(0, { value: amount });
    await escrow.connect(developer).submitProof(0, 'ipfs://proof', 'https://github.com/example/project', 'https://demo.example', 'Tested locally');
    await escrow.connect(recruiter).approve(0);

    await expect(escrow.connect(recruiter).release(0)).to.emit(escrow, 'EscrowReleased').withArgs(0, developer.address, amount);
    expect((await escrow.milestones(0)).status).to.equal(4n);
    await expect(escrow.connect(recruiter).release(0)).to.be.revertedWith('not approved');
  });

  it('refunds a hired milestone on participant cancellation', async () => {
    const [developer, recruiter] = await ethers.getSigners();
    const escrow = await ethers.deployContract('LocalWeb3LinkedInEscrow');
    const amount = ethers.parseEther('0.25');

    await escrow.connect(developer).createMilestone('Research', amount);
    await escrow.connect(recruiter).hire(0, { value: amount });
    await expect(escrow.connect(recruiter).cancel(0)).to.emit(escrow, 'MilestoneCancelled');
    expect((await escrow.milestones(0)).status).to.equal(5n);
  });

  it('blocks a frozen developer from creating new work', async () => {
    const [developer] = await ethers.getSigners();
    const escrow = await ethers.deployContract('LocalWeb3LinkedInEscrow');
    await escrow.connect(developer).freezeProfile();
    await expect(escrow.connect(developer).createMilestone('Blocked', 1)).to.be.revertedWith('profile frozen');
  });
});