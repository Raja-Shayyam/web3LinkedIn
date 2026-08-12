// Contract ABI from Hardhat compilation
import abi from '../../artifacts/web3-linkedin/contract-abi.json';

export const ESCROW_ABI = abi as any[];

// Will be populated after deployment
// @ts-ignore - Vite specific import.meta.env
const env = (import.meta as any).env;
export const ESCROW_ADDRESS = env?.VITE_ESCROW_ADDRESS || '0x5FbDB2315678afecb367f032d93F642f64180aa3';
