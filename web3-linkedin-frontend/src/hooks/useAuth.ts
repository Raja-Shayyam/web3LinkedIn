// src/hooks/useAuth.ts

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
  completeSignup: (email: string, name: string, role: UserRole) => Promise<void>;
  logout: () => void;
  error: string | null;
}

const API = import.meta.env.VITE_API_URL || '/api';
const PROFILE_KEY = 'web3linkedin_user_profile';

declare global {
  interface Window {
    ethereum?: any;
  }
}

function notifyAuth() {
  window.dispatchEvent(new Event('web3linkedin-auth-change'));
}

export function useAuth(): UseAuthResult {
  const [walletAddress, setWalletAddress] = useState<string | null>(null);
  const [signer, setSigner] = useState<ethers.Signer | null>(null);
  const [userProfile, setUserProfile] = useState<UserProfile | null>(null);
  const [userEmail, setUserEmail] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const loadProfile = useCallback(async (address: string) => {
    try {
      const response = await fetch(`${API}/users/${address}`);
      if (response.ok) {
        const { user, profile } = await response.json();
        const next: UserProfile = {
          walletAddress: user.wallet_address,
          email: user.email,
          name: user.name,
          role: user.role,
          trustScore: profile?.trust_score || 0,
          signupTimestamp: new Date(user.created_at).getTime(),
          isProfileFrozen: false,
        };
        setUserProfile(next);
        setUserEmail(user.email);
        localStorage.setItem(PROFILE_KEY, JSON.stringify(next));
      } else {
        setUserProfile(null);
      }
    } catch {
      setUserProfile(null);
    }
  }, []);

  useEffect(() => {
    const hydrate = async () => {
      if (!window.ethereum) {
        setIsLoading(false);
        return;
      }
      try {
        const provider = new ethers.BrowserProvider(window.ethereum);
        const accounts = await provider.listAccounts();
        if (accounts[0]) {
          setWalletAddress(accounts[0].address);
          setSigner(await provider.getSigner());
          await loadProfile(accounts[0].address);
        }
      } finally {
        setIsLoading(false);
      }
    };

    hydrate();

    const onAccounts = async (accounts: string[]) => {
      if (!accounts[0]) {
        setWalletAddress(null);
        setSigner(null);
        setUserProfile(null);
      } else {
        const provider = new ethers.BrowserProvider(window.ethereum);
        setWalletAddress(accounts[0]);
        setSigner(await provider.getSigner());
        await loadProfile(accounts[0]);
      }
    };

    const onAuthChange = () => {
      const cached = localStorage.getItem(PROFILE_KEY);
      if (cached) {
        const next = JSON.parse(cached);
        setUserProfile(next);
        setWalletAddress(next.walletAddress);
      }
    };

    window.ethereum?.on('accountsChanged', onAccounts);
    window.addEventListener('web3linkedin-auth-change', onAuthChange);

    return () => {
      window.ethereum?.removeListener('accountsChanged', onAccounts);
      window.removeEventListener('web3linkedin-auth-change', onAuthChange);
    };
  }, [loadProfile]);

  const connectWallet = async () => {
    setError(null);
    if (!window.ethereum) {
      setError('Install MetaMask or another compatible wallet to continue.');
      return;
    }
    try {
      const provider = new ethers.BrowserProvider(window.ethereum);
      const accounts = await provider.send('eth_requestAccounts', []);
      setWalletAddress(accounts[0]);
      setSigner(await provider.getSigner());
      await loadProfile(accounts[0]);
      notifyAuth();
    } catch (err: any) {
      setError(err.message || 'Wallet connection failed.');
    }
  };

  const completeSignup = async (email: string, name: string, role: UserRole) => {
    setError(null);
    if (!signer || !walletAddress) throw new Error('Connect a wallet first.');

    try {
      // ── 1. Fetch nonce (with ok check before .json()) ─────────
      const nonceResponse = await fetch(`${API}/auth/nonce/${walletAddress}`);

      if (!nonceResponse.ok) {
        let detail = nonceResponse.statusText;
        try {
          const body = await nonceResponse.json();
          detail = body.error || body.message || detail;
        } catch {
          /* body was empty or not JSON — use statusText */
        }
        throw new Error(`Nonce request failed: ${detail}`);
      }

      const { nonce } = await nonceResponse.json();

      // ── 2. Sign SIWE message ──────────────────────────────────
      const network = await signer.provider?.getNetwork();
      const chainId = Number(network?.chainId || 1);
      const issuedAt = new Date().toISOString();

      const messageText =
        `${window.location.host} wants you to sign in with your Ethereum account:\n` +
        `${walletAddress}\n\n` +
        `Sign in to Web3LinkedIn and create your professional profile.\n\n` +
        `URI: ${window.location.origin}\n` +
        `Version: 1\n` +
        `Chain ID: ${chainId}\n` +
        `Nonce: ${nonce}\n` +
        `Issued At: ${issuedAt}`;

      const signature = await signer.signMessage(messageText);

      // ── 3. Verify & create profile (ok check BEFORE .json()) ──
      const response = await fetch(`${API}/auth/verify`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ message: messageText, signature, email, name, role }),
      });

      if (!response.ok) {
        let detail = response.statusText;
        try {
          const body = await response.json();
          detail = body.error || body.message || detail;
        } catch {
          /* body was empty or not JSON — use statusText */
        }
        throw new Error(detail || 'Profile verification failed.');
      }

      const data = await response.json();

      // ── 4. Update local state ─────────────────────────────────
      const profile: UserProfile = {
        walletAddress: data.user.wallet_address,
        email: data.user.email,
        name: data.user.name,
        role: data.user.role,
        trustScore: data.profile?.trust_score || 0,
        signupTimestamp: new Date(data.user.created_at).getTime(),
        isProfileFrozen: false,
      };

      setUserProfile(profile);
      setUserEmail(email);
      localStorage.setItem(PROFILE_KEY, JSON.stringify(profile));
      notifyAuth();
    } catch (err: any) {
      setError(err.message || 'Signup failed.');
      throw err;
    }
  };

  const logout = () => {
    localStorage.removeItem(PROFILE_KEY);
    setUserProfile(null);
    setUserEmail(null);
    notifyAuth();
  };

  const disconnectWallet = () => {
    setWalletAddress(null);
    setSigner(null);
    setUserProfile(null);
  };

  return {
    isAuthenticated: !!walletAddress && !!userProfile,
    isLoading,
    walletAddress,
    userEmail,
    userProfile,
    connectWallet,
    disconnectWallet,
    completeSignup,
    logout,
    error,
  };
}