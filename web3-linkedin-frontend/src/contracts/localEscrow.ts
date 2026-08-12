import { ethers } from 'ethers';
import deployment from './local-deployment.json';
import escrowAbi from './MilestoneEscrow.abi.json';

export const HARDHAT_CHAIN_ID = 31337;
export const ESCROW_ADDRESS = deployment.MilestoneEscrow;
export const USDC_ADDRESS = deployment.MockUSDC;
const ERC20_ABI = ['function approve(address spender,uint256 amount) external returns (bool)', 'function decimals() view returns (uint8)'];

export async function getLocalSigner() {
  if (!window.ethereum) throw new Error('Install MetaMask to use local blockchain actions.');
  const provider = new ethers.BrowserProvider(window.ethereum);
  const network = await provider.getNetwork();
  if (Number(network.chainId) !== HARDHAT_CHAIN_ID) throw new Error('Switch MetaMask to Hardhat Local (chain ID 31337).');
  return provider.getSigner();
}

export async function createAndFundEscrow(freelancer: string, amount: string, description: string) {
  const signer = await getLocalSigner();
  const escrow = new ethers.Contract(ESCROW_ADDRESS, escrowAbi as ethers.InterfaceAbi, signer);
  const token = new ethers.Contract(USDC_ADDRESS, ERC20_ABI, signer);
  const decimals = await token.decimals();
  const units = ethers.parseUnits(amount, decimals);
  const hash = ethers.keccak256(ethers.toUtf8Bytes(description));
  const createTx = await escrow.createContract(freelancer, USDC_ADDRESS, [units], [hash]);
  const createReceipt = await createTx.wait();
  const created = createReceipt.logs.map((log: any) => { try { return escrow.interface.parseLog(log); } catch { return null; } }).find((event: any) => event?.name === 'ContractCreated');
  const contractId = created?.args?.contractId ?? 0n;
  const approveTx = await token.approve(ESCROW_ADDRESS, units);
  await approveTx.wait();
  const fundTx = await escrow.fundContract(contractId);
  await fundTx.wait();
  return { contractId: contractId.toString(), txHash: fundTx.hash };
}

export async function startEscrow(contractId: string) { const signer = await getLocalSigner(); const c = new ethers.Contract(ESCROW_ADDRESS, escrowAbi as ethers.InterfaceAbi, signer); const tx = await c.startWork(contractId); return tx.wait(); }
export async function submitEscrow(contractId: string, evidence: string) { const signer = await getLocalSigner(); const c = new ethers.Contract(ESCROW_ADDRESS, escrowAbi as ethers.InterfaceAbi, signer); const tx = await c.submitMilestone(contractId, 0, ethers.keccak256(ethers.toUtf8Bytes(evidence))); return tx.wait(); }
export async function approveEscrow(contractId: string) { const signer = await getLocalSigner(); const c = new ethers.Contract(ESCROW_ADDRESS, escrowAbi as ethers.InterfaceAbi, signer); const tx = await c.approveMilestone(contractId, 0); return tx.wait(); }
export async function readEscrow(contractId: string) { const provider = new ethers.JsonRpcProvider('http://127.0.0.1:8545'); const c = new ethers.Contract(ESCROW_ADDRESS, escrowAbi as ethers.InterfaceAbi, provider); return c.getContract(contractId); }
