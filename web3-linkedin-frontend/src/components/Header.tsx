import React from 'react';
import { useAuth } from '../hooks/useAuth';

export function Header() {
  const { 
    isAuthenticated, 
    walletAddress, 
    userProfile, 
    connectWallet, 
    logout,
    isLoading 
  } = useAuth();

  const handleConnectWallet = async () => {
    await connectWallet();
  };

  const formatAddress = (address: string) => {
    return `${address.slice(0, 6)}...${address.slice(-4)}`;
  };

  return (
    <header style={styles.header}>
      <div style={styles.container}>
        <div style={styles.logo}>
          <span style={styles.logoIcon}>🔗</span>
          <h1 style={styles.logoText}>Web3LinkedIn</h1>
        </div>

        <nav style={styles.nav}>
          {isAuthenticated ? (
            <>
              <div style={styles.userInfo}>
                <span style={styles.userName}>{userProfile?.name || 'User'}</span>
                <span style={styles.userRole}>{userProfile?.role}</span>
                <span style={styles.walletAddress}>{walletAddress && formatAddress(walletAddress)}</span>
              </div>
              <button onClick={logout} style={styles.logoutButton}>
                Logout
              </button>
            </>
          ) : (
            <button 
              onClick={handleConnectWallet} 
              style={styles.connectButton}
              disabled={isLoading}
            >
              {isLoading ? 'Connecting...' : 'Connect Wallet'}
            </button>
          )}
        </nav>
      </div>
    </header>
  );
}

const styles: Record<string, React.CSSProperties> = {
  header: {
    backgroundColor: '#0a66c2',
    padding: '12px 0',
    borderBottom: '1px solid #ddd'
  },
  container: {
    maxWidth: '1200px',
    margin: '0 auto',
    padding: '0 24px',
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center'
  },
  logo: {
    display: 'flex',
    alignItems: 'center',
    gap: '12px'
  },
  logoIcon: {
    fontSize: '28px'
  },
  logoText: {
    fontSize: '20px',
    fontWeight: 'bold',
    color: '#fff',
    margin: 0
  },
  nav: {
    display: 'flex',
    alignItems: 'center',
    gap: '16px'
  },
  userInfo: {
    display: 'flex',
    alignItems: 'center',
    gap: '12px',
    color: '#fff'
  },
  userName: {
    fontWeight: '600',
    fontSize: '14px'
  },
  userRole: {
    fontSize: '12px',
    backgroundColor: 'rgba(255,255,255,0.2)',
    padding: '2px 8px',
    borderRadius: '12px',
    textTransform: 'capitalize'
  },
  walletAddress: {
    fontSize: '12px',
    fontFamily: 'monospace',
    backgroundColor: 'rgba(255,255,255,0.1)',
    padding: '2px 6px',
    borderRadius: '4px'
  },
  connectButton: {
    backgroundColor: '#fff',
    color: '#0a66c2',
    border: 'none',
    padding: '8px 16px',
    borderRadius: '20px',
    fontWeight: '600',
    fontSize: '14px',
    cursor: 'pointer'
  },
  logoutButton: {
    backgroundColor: 'transparent',
    color: '#fff',
    border: '1px solid rgba(255,255,255,0.5)',
    padding: '8px 16px',
    borderRadius: '20px',
    fontWeight: '600',
    fontSize: '14px',
    cursor: 'pointer'
  }
};
