import { useEffect, useMemo, useState } from 'react';
import { useAuth } from './hooks/useAuth';
import { Header } from './components/Header';
import { SignupModal } from './components/SignupModal';
import { createAndFundEscrow } from './contracts/localEscrow';

type Project = { id: number; title: string; description: string; visibility: string; status: string; budget_eth: number; recruiter_name?: string; created_at: string };
type Milestone = { id: number; project_id: number; title: string; description: string; amount_eth: number; status: string; developer_name?: string; tx_hash?: string | null };
const API = 'http://localhost:3001/api';

function App() {
  const { isAuthenticated, walletAddress, userProfile, isLoading, error: authError } = useAuth();
  const [showSignupModal, setShowSignupModal] = useState(false);
  const [projects, setProjects] = useState<Project[]>([]);
  const [milestones, setMilestones] = useState<Milestone[]>([]);
  const [activeView, setActiveView] = useState('overview');
  const [showProjectForm, setShowProjectForm] = useState(false);
  const [notice, setNotice] = useState('');
  const [projectForm, setProjectForm] = useState({ title: '', description: '', budget_eth: '0.1', visibility: 'public' });

  useEffect(() => {
    if (walletAddress && !userProfile && !isLoading) setShowSignupModal(true);
  }, [walletAddress, userProfile, isLoading]);

  useEffect(() => {
    fetch(`${API}/projects`).then((r) => r.ok ? r.json() : { projects: [] }).then((data) => setProjects(data.projects || [])).catch(() => setProjects([]));
  }, [isAuthenticated]);

  useEffect(() => {
    if (!projects.length) return;
    Promise.all(projects.map((p) => fetch(`${API}/projects/${p.id}/milestones`).then((r) => r.json()).catch(() => ({ milestones: [] })))).then((items) => setMilestones(items.flatMap((item) => item.milestones || [])));
  }, [projects]);

  const myProjects = useMemo(() => projects.filter((project) => project.recruiter_name === userProfile?.name), [projects, userProfile]);
  const activeMilestones = milestones.filter((m) => ['active', 'pending', 'submitted'].includes(m.status));

  async function startEscrowDemo() {
    try {
      if (!walletAddress) throw new Error('Connect a wallet first.');
      const result = await createAndFundEscrow(walletAddress, '1', 'Web3LinkedIn MVP milestone');
      setNotice(`Escrow funded on Hardhat. Contract #${result.contractId}; tx ${result.txHash.slice(0, 10)}...`);
    } catch (error: any) {
      setNotice(error?.shortMessage || error?.message || 'Escrow transaction failed.');
    }
  }

  async function createProject(event: React.FormEvent) {
    event.preventDefault();
    if (!userProfile) return;
    const userResponse = await fetch(`${API}/users/${walletAddress}`);
    const { user } = await userResponse.json();
    const response = await fetch(`${API}/projects`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ recruiter_id: user.id, ...projectForm, budget_eth: Number(projectForm.budget_eth) }) });
    if (!response.ok) { setNotice('Only recruiter profiles can publish projects.'); return; }
    const data = await response.json();
    setProjects((current) => [data.project, ...current]); setShowProjectForm(false); setProjectForm({ title: '', description: '', budget_eth: '0.1', visibility: 'public' }); setNotice('Project published successfully.');
  }

  if (isLoading) return <div className="loading-screen"><div className="mark">W</div><p>Preparing your workspace</p></div>;

  return <div className="app-shell">
    <Header />
    {!isAuthenticated ? <main className="landing-main">
      <section className="hero-section"><div className="eyebrow">THE PROFESSIONAL LAYER FOR WEB3</div><h1>Work you can <span>verify.</span><br />People you can trust.</h1><p className="hero-copy">A wallet-native professional network for discovering talent, showcasing real work, and completing projects with milestone-protected payments.</p><div className="hero-actions"><button className="primary-button" onClick={() => document.querySelector<HTMLButtonElement>('.connect-button')?.click()}>Connect wallet <span>→</span></button><span className="quiet-note">No gas required to create your profile</span></div></section>
      <section className="signal-grid"><div className="signal-card"><span className="signal-index">01</span><strong>Own your identity</strong><p>Your profile is anchored to a wallet you control.</p></div><div className="signal-card"><span className="signal-index">02</span><strong>Show real work</strong><p>Projects, proof and reputation in one place.</p></div><div className="signal-card"><span className="signal-index">03</span><strong>Get paid fairly</strong><p>Milestones keep both sides accountable.</p></div></section>
    </main> : <main className="workspace"><aside className="sidebar"><div className="side-label">WORKSPACE</div>{['overview', 'projects', 'contracts', 'profile'].map((view) => <button key={view} className={`side-link ${activeView === view ? 'active' : ''}`} onClick={() => setActiveView(view)}><span className="side-dot" />{view[0].toUpperCase() + view.slice(1)}{view === 'contracts' && activeMilestones.length > 0 && <small>{activeMilestones.length}</small>}</button>)}<div className="side-footer"><span className="status-dot" />Testnet connected</div></aside>
      <section className="content"><div className="content-top"><div><div className="eyebrow">{userProfile?.role === 'recruiter' ? 'RECRUITER WORKSPACE' : 'DEVELOPER WORKSPACE'}</div><h1>{activeView === 'overview' ? `Good to see you, ${userProfile?.name?.split(' ')[0]}.` : activeView[0].toUpperCase() + activeView.slice(1)}</h1><p className="muted">{activeView === 'overview' ? 'Your professional graph, at a glance.' : 'Keep the important work moving.'}</p></div>{userProfile?.role === 'recruiter' && <button className="primary-button compact" onClick={() => setShowProjectForm(true)}>+ Publish project</button>}</div>{notice && <div className="notice">{notice}<button onClick={() => setNotice('')}>×</button></div>}
        {activeView === 'overview' && <><div className="stat-row"><div className="stat-card"><span>PROFILE STATUS</span><strong>Verified</strong><em>Wallet ownership confirmed</em></div><div className="stat-card"><span>PROJECTS</span><strong>{myProjects.length || projects.length}</strong><em>Public opportunities</em></div><div className="stat-card"><span>TRUST SCORE</span><strong>{userProfile?.trustScore ?? 0}</strong><em>Built through completed work</em></div></div><div className="section-grid"><div className="panel"><div className="panel-heading"><div><span className="eyebrow">DISCOVER</span><h2>Open projects</h2></div><button className="text-button" onClick={() => setActiveView('projects')}>View all →</button></div>{projects.length ? projects.slice(0, 3).map((project) => <ProjectRow key={project.id} project={project} onClick={() => setNotice('Project details and access requests are next in the MVP flow.')} />) : <EmptyState text="No projects published yet." />}</div><div className="panel activity-panel"><div className="panel-heading"><div><span className="eyebrow">ON-CHAIN ACTIVITY</span><h2>Recent signals</h2></div></div><div className="activity-item"><span className="activity-icon">↗</span><div><strong>Wallet connected</strong><p>Identity established on testnet</p></div><time>Now</time></div><div className="activity-item"><span className="activity-icon">◇</span><div><strong>Reputation initialized</strong><p>Score starts at zero by design</p></div><time>Today</time></div></div></div></>}
        {activeView === 'projects' && <div className="panel full-panel"><div className="panel-heading"><div><span className="eyebrow">PROJECT DIRECTORY</span><h2>Work looking for talent</h2></div>{userProfile?.role === 'recruiter' && <button className="primary-button compact" onClick={() => setShowProjectForm(true)}>+ New project</button>}</div>{projects.length ? projects.map((project) => <ProjectRow key={project.id} project={project} onClick={() => setNotice('Access request flow will use this project as its starting point.')} />) : <EmptyState text="The directory is empty. Publish the first project." />}</div>}
        {activeView === 'contracts' && <div className="panel full-panel"><div className="panel-heading"><div><span className="eyebrow">MILESTONE ESCROW</span><h2>Your contracts</h2></div></div>{milestones.length ? milestones.map((milestone) => <div className="contract-row" key={milestone.id}><div className="contract-status"><span className={`status-pill ${milestone.status}`}>{milestone.status}</span><strong>{milestone.title}</strong><p>{milestone.description}</p></div><div className="contract-amount"><strong>{milestone.amount_eth} ETH</strong><span>Milestone amount</span></div><button className="outline-button" onClick={startEscrowDemo}>Fund on Hardhat</button></div>) : <EmptyState text="Your milestone contracts will appear here." />}</div>}
        {activeView === 'profile' && <div className="profile-layout"><div className="profile-card"><div className="avatar">{userProfile?.name?.slice(0, 1) || 'W'}</div><span className="eyebrow">{userProfile?.role}</span><h2>{userProfile?.name}</h2><p className="muted">{userProfile?.email}</p><div className="wallet-line">{walletAddress?.slice(0, 10)}...{walletAddress?.slice(-8)}</div></div><div className="panel"><div className="panel-heading"><div><span className="eyebrow">PUBLIC PROFILE</span><h2>Trust, without the noise</h2></div></div><p className="body-copy">Your public profile will become the home for verified projects, completed milestones and professional connections.</p><div className="profile-points"><div><strong>0</strong><span>Completed projects</span></div><div><strong>0</strong><span>Connections</span></div><div><strong>{userProfile?.trustScore ?? 0}</strong><span>Trust score</span></div></div></div></div>}
      </section></main>}
    <SignupModal isOpen={showSignupModal} onClose={() => setShowSignupModal(false)} />{authError && !isAuthenticated && <div className="toast-error">{authError}</div>}{showProjectForm && <div className="modal-backdrop"><form className="project-form" onSubmit={createProject}><button type="button" className="close-button" onClick={() => setShowProjectForm(false)}>×</button><span className="eyebrow">NEW OPPORTUNITY</span><h2>Publish a project</h2><p className="muted">Give the right builder enough signal to start a conversation.</p><label>Project title<input required value={projectForm.title} onChange={(e) => setProjectForm({ ...projectForm, title: e.target.value })} placeholder="Build a token-gated portfolio" /></label><label>Description<textarea required value={projectForm.description} onChange={(e) => setProjectForm({ ...projectForm, description: e.target.value })} placeholder="What needs to be built?" /></label><div className="form-grid"><label>Budget (ETH)<input type="number" min="0" step="0.01" value={projectForm.budget_eth} onChange={(e) => setProjectForm({ ...projectForm, budget_eth: e.target.value })} /></label><label>Visibility<select value={projectForm.visibility} onChange={(e) => setProjectForm({ ...projectForm, visibility: e.target.value })}><option value="public">Public</option><option value="private">Private</option></select></label></div><button className="primary-button" type="submit">Publish project →</button></form></div>}
  </div>;
}
function ProjectRow({ project, onClick }: { project: Project; onClick: () => void }) { return <button className="project-row" onClick={onClick}><span className="project-mark">{project.title.slice(0, 1)}</span><span className="project-copy"><strong>{project.title}</strong><p>{project.description}</p></span><span className="project-meta"><b>{project.budget_eth} ETH</b><small>{project.status}</small></span><span className="arrow">→</span></button>; }
function EmptyState({ text }: { text: string }) { return <div className="empty-state"><span>◇</span><p>{text}</p></div>; }
export default App;
