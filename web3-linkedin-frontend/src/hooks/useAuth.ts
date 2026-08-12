import { useState, useEffect, useCallback } from 'react';
import { ethers } from 'ethers';

export type UserRole = 'developer' | 'recruiter';

export interface UserProfile {
  walletAddress: string;
  email?: string;
  name?: string;
  role: UserRole;
  trustScore: number;
  signupTimestamp?: number;
  isProfileFrozen: boolean;
}

interface UseAuthResult {
  isAuthenticated: boolean;
  isLoading: boolean;
  walletAddress: string | null;
  userEmail: string | null;
  userProfile: UserProfile | null;
  connectWallet: () => Promise<void>;
  disconnectWallet: () => void;
  generateNonce: () => string;
  requireWalletSignature: (nonce: string) => Promise<string>;
  completeSignup: (email: string, name: string, role: UserRole, signature: string) => Promise<void>;
  logout: () => void;
  error: string | null;
}

const STORAGE_KEYS = {
  USER_PROFILE: 'web3linkedin_user_profile',
  USER_EMAIL: 'web3linkedin_user_email',
  USER_NONCE: 'web3linkedin_nonce'
};

declare global {
  interface Window {
    ethereum?: any;
  }
}

export function useAuth(): UseAuthResult {
  const [walletAddress, setWalletAddress] = useState<string | null>(null);
  const [signer, setSigner] = useState<ethers.Signer | null>(null);
  const [userProfile, setUserProfile] = useState<UserProfile | null>(null);
  const [userEmail, setUserEmail] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [currentNonce, setCurrentNonce] = useState<string>('');

  // Load stored user data on mount
  useEffect(() => {
    try {
      const storedProfile = localStorage.getItem(STORAGE_KEYS.USER_PROFILE);
      const storedEmail = localStorage.getItem(STORAGE_KEYS.USER_EMAIL);
      if (storedProfile) setUserProfile(JSON.parse(storedProfile));
      if (storedEmail) setUserEmail(storedEmail);
    } catch (err) {
      console.error('Error loading user data:', err);
    } finally {
      setIsLoading(false);
    }
  }, []);

  // Check for existing wallet connection
  useEffect(() => {
    const checkConnection = async () => {
      if (typeof window.ethereum !== 'undefined') {
        try {
          const browserProvider = new ethers.BrowserProvider(window.ethereum);
          const accounts = await browserProvider.listAccounts();
          if (accounts.length > 0) {
            const address = accounts[0].address;
            setWalletAddress(address);
            const s = await browserProvider.getSigner();
            setSigner(s);
          }
        } catch (err) {
          console.error('Error checking wallet connection:', err);
        }
      }
    };
    checkConnection();

    if (typeof window.ethereum !== 'undefined') {
      window.ethereum.on('accountsChanged', (accounts: string[]) => {
        if (accounts.length > 0) {
          setWalletAddress(accounts[0]);
        } else {
          setWalletAddress(null);
          setSigner(null);
        }
      });

      window.ethereum.on('chainChanged', () => {
        window.location.reload();
      });
    }

    return () => {
      if (typeof window.ethereum !== 'undefined') {
        window.ethereum.removeAllListeners('accountsChanged');
        window.ethereum.removeAllListeners('chainChanged');
      }
    };
  }, []);

  const connectWallet = async () => {
    setError(null);
    if (typeof window.ethereum === 'undefined') {
      setError('Please install MetaMask or another Web3 wallet');
      return;
    }

    try {
      const browserProvider = new ethers.BrowserProvider(window.ethereum);
      const accounts = await browserProvider.send('eth_requestAccounts', []);
      const address = accounts[0];
      const s = await browserProvider.getSigner();
      
      setWalletAddress(address);
      setSigner(s);
    } catch (err: any) {
      setError(err.message || 'Failed to connect wallet');
    }
  };

  const disconnectWallet = () => {
    setWalletAddress(null);
    setSigner(null);
  };

  const generateNonce = useCallback(() => {
    const nonce = Math.random().toString(36).substring(2, 15) + 
                  Math.random().toString(36).substring(2, 15);
    localStorage.setItem(STORAGE_KEYS.USER_NONCE, nonce);
    setCurrentNonce(nonce);
    return nonce;
  }, []);

  const requireWalletSignature = async (nonce: string): Promise<string> => {
    if (!signer) throw new Error('Wallet not connected');
    const message = `Sign this message to prove ownership of your wallet.\n\nNonce: ${nonce}\nTimestamp: ${Date.now()}`;
    return await signer.signMessage(message);
  };

  const completeSignup = async (email: string, name: string, role: UserRole, signature: string) => {
    setError(null);
    setIsLoading(true);
    try {
      if (!signer) throw new Error('Wallet not connected');
      
      // Verify signature
      const message = `Sign this message to prove ownership of your wallet.\n\nNonce: ${currentNonce}\nTimestamp: ${Date.now()}`;
      const recoveredAddress = ethers.verifyMessage(message, signature);
      
      if (recoveredAddress.toLowerCase() !== walletAddress?.toLowerCase()) {
        throw new Error('Signature verification failed');
      }

      // Create user profile
      const profile: UserProfile = {
        walletAddress: walletAddress!,
        email,
        name,
        role,
        trustScore: 0, // Start with honest zero
        signupTimestamp: Date.now(),
        isProfileFrozen: false
      };

      // Store in localStorage (later move to backend DB)
      localStorage.setItem(STORAGE_KEYS.USER_PROFILE, JSON.stringify(profile));
      localStorage.setItem(STORAGE_KEYS.USER_EMAIL, email);
      
      setUserProfile(profile);
      setUserEmail(email);
    } catch (err: any) {
      setError(err.message || 'Signup failed');
      throw err;
    } finally {
      setIsLoading(false);
    }
  };

  const logout = () => {
    localStorage.removeItem(STORAGE_KEYS.USER_PROFILE);
    localStorage.removeItem(STORAGE_KEYS.USER_EMAIL);
    localStorage.removeItem(STORAGE_KEYS.USER_NONCE);
    setUserProfile(null);
    setUserEmail(null);
  };

  return {
    isAuthenticated: !!userProfile && !!walletAddress,
    isLoading,
    walletAddress,
    userEmail,
    userProfile,
    connectWallet,
    disconnectWallet,
    generateNonce,
    requireWalletSignature,
    completeSignup,
    logout,
    error
  };
}
