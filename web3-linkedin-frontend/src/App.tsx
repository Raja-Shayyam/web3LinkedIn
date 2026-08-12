import { useState, useEffect } from 'react';
import { useAuth } from './hooks/useAuth';
import { Header } from './components/Header';
import { SignupModal } from './components/SignupModal';

function App() {
  const { isAuthenticated, walletAddress, userProfile, isLoading } = useAuth();
  const [showSignupModal, setShowSignupModal] = useState(false);

  // Show signup modal when wallet is connected but no profile exists
  useEffect(() => {
    if (walletAddress && !userProfile && !isLoading) {
      setShowSignupModal(true);
    }
  }, [walletAddress, userProfile, isLoading]);

  if (isLoading) {
    return (
      <div style={styles.loadingContainer}>
        <div style={styles.spinner}></div>
        <p>Loading Web3LinkedIn...</p>
      </div>
    );
  }

  return (
    <div style={styles.app}>
      <Header />
      
      <main style={styles.main}>
        {!isAuthenticated ? (
          <div style={styles.landingPage}>
            <div style={styles.hero}>
              <h1 style={styles.heroTitle}>
                Welcome to <span style={styles.highlight}>Web3LinkedIn</span>
              </h1>
              <p style={styles.heroSubtitle}>
                The decentralized professional network powered by blockchain
              </p>
              
              <div style={styles.features}>
                <div style={styles.featureCard}>
                  <span style={styles.featureIcon}>🔐</span>
                  <h3>Wallet-Based Identity</h3>
                  <p>Own your professional identity with cryptographic verification</p>
                </div>
                
                <div style={styles.featureCard}>
                  <span style={styles.featureIcon}>💼</span>
                  <h3>Escrow Protection</h3>
                  <p>Smart contracts ensure fair payment for freelance work</p>
                </div>
                
                <div style={styles.featureCard}>
                  <span style={styles.featureIcon}>⭐</span>
                  <h3>On-Chain Reputation</h3>
                  <p>Build trust through verifiable project completions</p>
                </div>
              </div>

              <div style={styles.ctaSection}>
                <p style={styles.ctaText}>
                  Connect your wallet to get started
                </p>
              </div>
            </div>
          </div>
        ) : (
          <div style={styles.dashboard}>
            <div style={styles.welcomeCard}>
              <h2 style={styles.welcomeTitle}>
                Welcome back, {userProfile?.name}! 👋
              </h2>
              <p style={styles.welcomeSubtitle}>
                You're signed in as a <strong>{userProfile?.role}</strong>
              </p>
              
              <div style={styles.profileInfo}>
                <div style={styles.infoRow}>
                  <span style={styles.infoLabel}>Wallet:</span>
                  <span style={styles.infoValue}>{walletAddress}</span>
                </div>
                <div style={styles.infoRow}>
                  <span style={styles.infoLabel}>Trust Score:</span>
                  <span style={styles.trustScore}>{userProfile?.trustScore}</span>
                </div>
                <div style={styles.infoRow}>
                  <span style={styles.infoLabel}>Member Since:</span>
                  <span style={styles.infoValue}>
                    {userProfile?.signupTimestamp 
                      ? new Date(userProfile.signupTimestamp).toLocaleDateString() 
                      : 'N/A'}
                  </span>
                </div>
              </div>

              <div style={styles.comingSoon}>
                <h3>🚀 Coming Soon</h3>
                <ul style={styles.comingSoonList}>
                  <li>Create/view projects</li>
                  <li>Hire developers with escrow</li>
                  <li>Submit milestone proofs</li>
                  <li>Build on-chain reputation</li>
                  <li>Search & discovery</li>
                </ul>
              </div>
            </div>
          </div>
        )}
      </main>

      <SignupModal 
        isOpen={showSignupModal} 
        onClose={() => setShowSignupModal(false)} 
      />
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  app: {
    minHeight: '100vh',
    backgroundColor: '#f3f6f8',
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif'
  },
  loadingContainer: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: '100vh',
    backgroundColor: '#f3f6f8',
    gap: '16px'
  },
  spinner: {
    width: '40px',
    height: '40px',
    border: '4px solid #e0e0e0',
    borderTop: '4px solid #0a66c2',
    borderRadius: '50%',
    animation: 'spin 1s linear infinite'
  },
  main: {
    maxWidth: '1200px',
    margin: '0 auto',
    padding: '40px 24px'
  },
  landingPage: {
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    paddingTop: '40px'
  },
  hero: {
    textAlign: 'center',
    maxWidth: '800px'
  },
  heroTitle: {
    fontSize: '48px',
    fontWeight: 'bold',
    color: '#333',
    marginBottom: '16px'
  },
  highlight: {
    color: '#0a66c2'
  },
  heroSubtitle: {
    fontSize: '20px',
    color: '#666',
    marginBottom: '48px'
  },
  features: {
    display: 'grid',
    gridTemplateColumns: 'repeat(auto-fit, minmax(250px, 1fr))',
    gap: '24px',
    marginBottom: '48px'
  },
  featureCard: {
    backgroundColor: '#fff',
    padding: '24px',
    borderRadius: '12px',
    boxShadow: '0 2px 8px rgba(0,0,0,0.1)',
    textAlign: 'center'
  },
  featureIcon: {
    fontSize: '48px',
    display: 'block',
    marginBottom: '16px'
  },
  ctaSection: {
    marginTop: '32px'
  },
  ctaText: {
    fontSize: '18px',
    color: '#666'
  },
  dashboard: {
    display: 'flex',
    justifyContent: 'center',
    paddingTop: '20px'
  },
  welcomeCard: {
    backgroundColor: '#fff',
    padding: '40px',
    borderRadius: '12px',
    boxShadow: '0 2px 12px rgba(0,0,0,0.1)',
    maxWidth: '600px',
    width: '100%'
  },
  welcomeTitle: {
    fontSize: '28px',
    fontWeight: 'bold',
    color: '#333',
    marginBottom: '8px'
  },
  welcomeSubtitle: {
    fontSize: '16px',
    color: '#666',
    marginBottom: '32px'
  },
  profileInfo: {
    backgroundColor: '#f8f9fa',
    padding: '24px',
    borderRadius: '8px',
    marginBottom: '24px'
  },
  infoRow: {
    display: 'flex',
    justifyContent: 'space-between',
    padding: '12px 0',
    borderBottom: '1px solid #e0e0e0',
    fontSize: '14px'
  },
  infoLabel: {
    color: '#666',
    fontWeight: '500'
  },
  infoValue: {
    color: '#333',
    fontFamily: 'monospace',
    fontSize: '13px'
  },
  trustScore: {
    color: '#0a66c2',
    fontWeight: 'bold',
    fontSize: '18px'
  },
  comingSoon: {
    backgroundColor: '#fff9e6',
    padding: '20px',
    borderRadius: '8px',
    border: '1px solid #ffd700'
  },
  comingSoonList: {
    margin: '12px 0 0 0',
    paddingLeft: '20px',
    color: '#666',
    fontSize: '14px',
    lineHeight: '1.8'
  }
};

export default App;
