import { useAuth } from '../hooks/useAuth';

export function Header() {
  const { isAuthenticated, walletAddress, userProfile, connectWallet, logout, isLoading } = useAuth();
  const formatAddress = (address: string) => `${address.slice(0, 6)}...${address.slice(-4)}`;
  return <header className="site-header"><div className="header-inner"><a className="brand" href="/"><span className="mark">W</span><strong>Web3LinkedIn</strong></a><div className="header-actions">{isAuthenticated ? <div className="header-user"><div><b>{userProfile?.name || 'Member'}</b><small>{walletAddress && formatAddress(walletAddress)}</small></div><span className="role-badge">{userProfile?.role}</span><button className="logout-button" onClick={logout}>Log out</button></div> : <button className="connect-button" onClick={connectWallet} disabled={isLoading}>{isLoading ? 'Connecting...' : 'Connect wallet'}</button>}</div></div></header>;
}
