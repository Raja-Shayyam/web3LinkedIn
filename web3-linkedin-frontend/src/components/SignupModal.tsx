import React, { useState } from 'react';
import { useAuth, UserRole } from '../hooks/useAuth';

interface SignupModalProps {
  isOpen: boolean;
  onClose: () => void;
}

export function SignupModal({ isOpen, onClose }: SignupModalProps) {
  const { generateNonce, requireWalletSignature, completeSignup, error } = useAuth();
  const [email, setEmail] = useState('');
  const [name, setName] = useState('');
  const [role, setRole] = useState<UserRole>('developer');
  const [isSigning, setIsSigning] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);

  if (!isOpen) return null;

  const handleSignup = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsSubmitting(true);
    
    try {
      // Step 1: Generate nonce
      const nonce = generateNonce();
      
      // Step 2: Request signature
      setIsSigning(true);
      const signature = await requireWalletSignature(nonce);
      setIsSigning(false);
      
      // Step 3: Complete signup
      await completeSignup(email, name, role, signature);
      
      // Close modal on success
      onClose();
    } catch (err: any) {
      console.error('Signup error:', err);
      // Error is handled by the hook
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <div style={styles.overlay}>
      <div style={styles.modal}>
        <h2 style={styles.title}>Complete Your Profile</h2>
        <p style={styles.subtitle}>Join Web3LinkedIn as a {role === 'developer' ? 'Developer' : 'Recruiter'}</p>
        
        <form onSubmit={handleSignup} style={styles.form}>
          <div style={styles.field}>
            <label style={styles.label}>Full Name</label>
            <input
              type="text"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="John Doe"
              required
              style={styles.input}
            />
          </div>

          <div style={styles.field}>
            <label style={styles.label}>Email Address</label>
            <input
              type="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="john@example.com"
              required
              style={styles.input}
            />
          </div>

          <div style={styles.field}>
            <label style={styles.label}>I am a...</label>
            <div style={styles.roleSelector}>
              <button
                type="button"
                onClick={() => setRole('developer')}
                style={role === 'developer' ? styles.roleButtonActive : styles.roleButton}
              >
                Developer
              </button>
              <button
                type="button"
                onClick={() => setRole('recruiter')}
                style={role === 'recruiter' ? styles.roleButtonActive : styles.roleButton}
              >
                Recruiter
              </button>
            </div>
          </div>

          {error && <p style={styles.error}>{error}</p>}

          <div style={styles.actions}>
            <button
              type="button"
              onClick={onClose}
              style={styles.cancelButton}
              disabled={isSubmitting}
            >
              Cancel
            </button>
            <button
              type="submit"
              style={styles.submitButton}
              disabled={isSubmitting || isSigning}
            >
              {isSigning ? 'Signing with wallet...' : isSubmitting ? 'Creating profile...' : 'Complete Signup'}
            </button>
          </div>
        </form>

        <p style={styles.info}>
          🔐 You'll need to sign a message with your wallet to verify ownership. 
          This costs no gas and proves you own the wallet address.
        </p>
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  overlay: {
    position: 'fixed',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: 'rgba(0, 0, 0, 0.7)',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: 1000
  },
  modal: {
    backgroundColor: '#1e1e1e',
    borderRadius: '12px',
    padding: '32px',
    maxWidth: '480px',
    width: '90%',
    color: '#fff'
  },
  title: {
    fontSize: '24px',
    fontWeight: 'bold',
    marginBottom: '8px',
    textAlign: 'center'
  },
  subtitle: {
    fontSize: '14px',
    color: '#888',
    marginBottom: '24px',
    textAlign: 'center'
  },
  form: {
    display: 'flex',
    flexDirection: 'column',
    gap: '20px'
  },
  field: {
    display: 'flex',
    flexDirection: 'column',
    gap: '8px'
  },
  label: {
    fontSize: '14px',
    fontWeight: '500',
    color: '#ccc'
  },
  input: {
    padding: '12px',
    borderRadius: '8px',
    border: '1px solid #333',
    backgroundColor: '#2a2a2a',
    color: '#fff',
    fontSize: '14px'
  },
  roleSelector: {
    display: 'flex',
    gap: '12px'
  },
  roleButton: {
    flex: 1,
    padding: '12px',
    borderRadius: '8px',
    border: '1px solid #333',
    backgroundColor: '#2a2a2a',
    color: '#888',
    cursor: 'pointer',
    fontSize: '14px',
    fontWeight: '500'
  },
  roleButtonActive: {
    flex: 1,
    padding: '12px',
    borderRadius: '8px',
    border: '1px solid #0077b5',
    backgroundColor: '#0077b5',
    color: '#fff',
    cursor: 'pointer',
    fontSize: '14px',
    fontWeight: '500'
  },
  error: {
    color: '#ff6b6b',
    fontSize: '14px',
    textAlign: 'center'
  },
  actions: {
    display: 'flex',
    gap: '12px',
    marginTop: '8px'
  },
  cancelButton: {
    flex: 1,
    padding: '12px',
    borderRadius: '8px',
    border: 'none',
    backgroundColor: '#333',
    color: '#fff',
    cursor: 'pointer',
    fontSize: '14px',
    fontWeight: '500'
  },
  submitButton: {
    flex: 1,
    padding: '12px',
    borderRadius: '8px',
    border: 'none',
    backgroundColor: '#0077b5',
    color: '#fff',
    cursor: 'pointer',
    fontSize: '14px',
    fontWeight: '500'
  },
  info: {
    fontSize: '12px',
    color: '#888',
    marginTop: '20px',
    textAlign: 'center',
    lineHeight: '1.5'
  }
};
