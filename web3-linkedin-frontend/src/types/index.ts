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

export interface Milestone {
  id: number;
  developer: string;
  recruiter: string;
  amount: bigint;
  status: 'Open' | 'Hired' | 'Submitted' | 'Approved' | 'Paid' | 'Cancelled';
  escrowLocked: boolean;
  title: string;
  proofUrl: string;
  githubUrl: string;
  liveDemoUrl: string;
  notes: string;
}

export interface AuthState {
  isAuthenticated: boolean;
  walletAddress: string | null;
  userEmail: string | null;
  userProfile: UserProfile | null;
  isLoading: boolean;
}
