import express from 'express';
import cors from 'cors';
import { ethers } from 'ethers';
import { SiweMessage } from 'siwe';
import { readFile, writeFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const dbPath = join(__dirname, 'data', 'db.json');
const PORT = process.env.PORT || 3001;

const app = express();
app.use(cors());
app.use(express.json());

// Database helper functions
async function readDB() {
  const data = await readFile(dbPath, 'utf-8');
  return JSON.parse(data);
}

async function writeDB(data) {
  await writeFile(dbPath, JSON.stringify(data, null, 2));
}

// Health check
app.get('/healthz', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Get nonce for SIWE authentication
app.get('/api/auth/nonce/:wallet', async (req, res) => {
  try {
    const { wallet } = req.params;
    const db = await readDB();
    
    // Generate random nonce
    const nonce = Math.random().toString(36).substring(2, 15);
    const expiresAt = new Date(Date.now() + 15 * 60 * 1000); // 15 minutes
    
    // Store nonce
    db.nonces.push({
      wallet_address: wallet.toLowerCase(),
      nonce,
      expires_at: expiresAt.toISOString(),
      used: false,
      created_at: new Date().toISOString()
    });
    
    await writeDB(db);
    
    res.json({ nonce, expiresAt: expiresAt.toISOString() });
  } catch (error) {
    console.error('Error generating nonce:', error);
    res.status(500).json({ error: 'Failed to generate nonce' });
  }
});

// Verify SIWE signature and login/signup
app.post('/api/auth/verify', async (req, res) => {
  try {
    const { message, signature, name, email, role } = req.body;
    
    if (!message || !signature) {
      return res.status(400).json({ error: 'Missing message or signature' });
    }
    
    // Parse SIWE message
    const siweMessage = new SiweMessage(message);
    const verification = await siweMessage.verify({ signature });
    if (!verification.success) return res.status(400).json({ error: 'Signature verification failed' });
    const { address, chainId } = verification.data;
    
    const db = await readDB();
    const walletLower = address.toLowerCase();
    
    // Check if nonce is valid
    const nonceRecord = db.nonces.find(
      n => n.wallet_address === walletLower && !n.used && new Date(n.expires_at) > new Date()
    );
    
    if (!nonceRecord) {
      return res.status(400).json({ error: 'Invalid or expired nonce' });
    }
    
    // Mark nonce as used
    nonceRecord.used = true;
    
    // Find or create user
    let user = db.users.find(u => u.wallet_address.toLowerCase() === walletLower);
    
    if (!user) {
      // New user - create account
      if (!name || !email || !role) {
        return res.status(400).json({ 
          error: 'New users must provide name, email, and role' 
        });
      }
      
      const userId = db.users.length > 0 ? Math.max(...db.users.map(u => u.id)) + 1 : 1;
      user = {
        id: userId,
        google_id: null, // Will be linked later if Google OAuth is used
        email,
        name,
        wallet_address: walletLower,
        role: role === 'developer' || role === 'recruiter' ? role : 'developer',
        created_at: new Date().toISOString()
      };
      
      db.users.push(user);
      
      // Create empty profile
      db.profiles.push({
        id: userId,
        user_id: userId,
        bio: '',
        skills: '[]',
        experience_years: 0,
        portfolio_url: '',
        github_url: '',
        linkedin_url: '',
        trust_score: 0,
        is_verified: false,
        created_at: new Date().toISOString()
      });
      
      await writeDB(db);
      
      return res.json({ 
        user, 
        profile: db.profiles.find(p => p.user_id === userId),
        isNewUser: true 
      });
    }
    
    // Existing user - just return
    const profile = db.profiles.find(p => p.user_id === user.id);
    await writeDB(db);
    
    res.json({ user, profile, isNewUser: false });
  } catch (error) {
    console.error('Error verifying signature:', error);
    res.status(400).json({ error: 'Signature verification failed' });
  }
});

// Get user by wallet
app.get('/api/users/:wallet', async (req, res) => {
  try {
    const { wallet } = req.params;
    const db = await readDB();
    
    const user = db.users.find(u => u.wallet_address.toLowerCase() === wallet.toLowerCase());
    
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }
    
    const profile = db.profiles.find(p => p.user_id === user.id);
    
    res.json({ user, profile });
  } catch (error) {
    console.error('Error fetching user:', error);
    res.status(500).json({ error: 'Failed to fetch user' });
  }
});

// Update profile
app.put('/api/users/:wallet/profile', async (req, res) => {
  try {
    const { wallet } = req.params;
    const { name, email, bio, skills, experience_years, portfolio_url, github_url, linkedin_url } = req.body;
    
    const db = await readDB();
    const user = db.users.find(u => u.wallet_address.toLowerCase() === wallet.toLowerCase());
    
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }
    
    if (name !== undefined) user.name = String(name).trim();
    if (email !== undefined) user.email = String(email).trim();
    const profile = db.profiles.find(p => p.user_id === user.id);
    
    if (profile) {
      if (bio !== undefined) profile.bio = bio;
      if (skills !== undefined) profile.skills = JSON.stringify(skills);
      if (experience_years !== undefined) profile.experience_years = experience_years;
      if (portfolio_url !== undefined) profile.portfolio_url = portfolio_url;
      if (github_url !== undefined) profile.github_url = github_url;
      if (linkedin_url !== undefined) profile.linkedin_url = linkedin_url;
      
      profile.updated_at = new Date().toISOString();
      await writeDB(db);
    }
    
    res.json({ profile });
  } catch (error) {
    console.error('Error updating profile:', error);
    res.status(500).json({ error: 'Failed to update profile' });
  }
});

// Get all projects (for feed)
app.get('/api/projects', async (req, res) => {
  try {
    const { visibility = 'public', recruiter_id } = req.query;
    const db = await readDB();
    
    let projects = db.projects;
    
    // Filter by visibility
    if (visibility) {
      projects = projects.filter(p => p.visibility === visibility);
    }
    
    // Filter by recruiter
    if (recruiter_id) {
      projects = projects.filter(p => p.recruiter_id === Number(String(recruiter_id)));
    }
    
    // Add recruiter info
    const projectsWithDetails = projects.map(project => {
      const recruiter = db.users.find(u => u.id === project.recruiter_id);
      return {
        ...project,
        recruiter_name: recruiter?.name,
        recruiter_wallet: recruiter?.wallet_address
      };
    });
    
    res.json({ projects: projectsWithDetails });
  } catch (error) {
    console.error('Error fetching projects:', error);
    res.status(500).json({ error: 'Failed to fetch projects' });
  }
});

// Create project
app.post('/api/projects', async (req, res) => {
  try {
    const { recruiter_id, title, description, visibility, budget_eth } = req.body;
    
    if (!recruiter_id || !title || !description) {
      return res.status(400).json({ error: 'Missing required fields' });
    }
    
    const db = await readDB();
    
    // Verify recruiter exists and has recruiter role
    const recruiter = db.users.find(u => u.id === recruiter_id);
    if (!recruiter || recruiter.role !== 'recruiter') {
      return res.status(403).json({ error: 'Only recruiters can create projects' });
    }
    
    const projectId = db.projects.length > 0 ? Math.max(...db.projects.map(p => p.id)) + 1 : 1;
    
    const project = {
      id: projectId,
      recruiter_id,
      title,
      description,
      visibility: visibility || 'public',
      status: 'open',
      budget_eth: budget_eth || 0,
      ipfs_hash: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    };
    
    db.projects.push(project);
    await writeDB(db);
    
    res.status(201).json({ project });
  } catch (error) {
    console.error('Error creating project:', error);
    res.status(500).json({ error: 'Failed to create project' });
  }
});

// Get milestones for a project
app.get('/api/projects/:projectId/milestones', async (req, res) => {
  try {
    const { projectId } = req.params;
    const db = await readDB();
    
    const milestones = db.milestones.filter(m => m.project_id === parseInt(projectId));
    
    // Add developer info
    const milestonesWithDetails = milestones.map(milestone => {
      const developer = db.users.find(u => u.id === milestone.developer_id);
      return {
        ...milestone,
        developer_name: developer?.name,
        developer_wallet: developer?.wallet_address
      };
    });
    
    res.json({ milestones: milestonesWithDetails });
  } catch (error) {
    console.error('Error fetching milestones:', error);
    res.status(500).json({ error: 'Failed to fetch milestones' });
  }
});

// Create milestone (hire developer)
app.post('/api/projects/:projectId/milestones', async (req, res) => {
  try {
    const { projectId } = req.params;
    const { developer_id, title, description, amount_eth } = req.body;
    
    if (!developer_id || !title || !description || !amount_eth) {
      return res.status(400).json({ error: 'Missing required fields' });
    }
    
    const db = await readDB();
    
    // Verify project exists
    const project = db.projects.find(p => p.id === parseInt(projectId));
    if (!project) {
      return res.status(404).json({ error: 'Project not found' });
    }
    
    // Verify developer exists
    const developer = db.users.find(u => u.id === developer_id);
    if (!developer || developer.role !== 'developer') {
      return res.status(400).json({ error: 'Invalid developer' });
    }
    
    const milestoneId = db.milestones.length > 0 ? Math.max(...db.milestones.map(m => m.id)) + 1 : 1;
    
    const milestone = {
      id: milestoneId,
      project_id: parseInt(projectId),
      developer_id,
      title,
      description,
      amount_eth,
      status: 'pending', // Will become 'active' after on-chain hire
      contract_address: null,
      tx_hash: null,
      proof_ipfs_hash: null,
      approved_at: null,
      paid_at: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    };
    
    db.milestones.push(milestone);
    await writeDB(db);
    
    res.status(201).json({ milestone });
  } catch (error) {
    console.error('Error creating milestone:', error);
    res.status(500).json({ error: 'Failed to create milestone' });
  }
});

// Update milestone (for on-chain events)
app.put('/api/milestones/:milestoneId', async (req, res) => {
  try {
    const { milestoneId } = req.params;
    const updates = req.body;
    
    const db = await readDB();
    const milestone = db.milestones.find(m => m.id === parseInt(milestoneId));
    
    if (!milestone) {
      return res.status(404).json({ error: 'Milestone not found' });
    }
    
    // Update allowed fields
    const allowedFields = ['status', 'contract_address', 'tx_hash', 'proof_ipfs_hash', 'approved_at', 'paid_at'];
    for (const field of allowedFields) {
      if (updates[field] !== undefined) {
        milestone[field] = updates[field];
      }
    }
    
    milestone.updated_at = new Date().toISOString();
    await writeDB(db);
    
    res.json({ milestone });
  } catch (error) {
    console.error('Error updating milestone:', error);
    res.status(500).json({ error: 'Failed to update milestone' });
  }
});

app.get('/api/posts', async (_req, res) => {
  const db = await readDB();
  const posts = (db.posts || []).map((post) => ({ ...post, author: db.users.find((user) => user.id === post.author_id) }));
  res.json({ posts });
});

app.post('/api/posts', async (req, res) => {
  const { wallet, content, title = '', post_type = 'project_update', skills = [], links = [], image_url = '' } = req.body;
  if (!wallet || !String(title || '').trim() || !String(content || '').trim()) return res.status(400).json({ error: 'Post title and details are required' });
  const db = await readDB();
  const author = db.users.find((user) => user.wallet_address.toLowerCase() === String(wallet).toLowerCase());
  if (!author || author.role !== 'developer') return res.status(403).json({ error: 'Only student/developer profiles can publish posts' });
  db.posts ||= [];
  const post = { id: db.posts.length ? Math.max(...db.posts.map((item) => item.id)) + 1 : 1, author_id: author.id, post_type, title: String(title).trim(), content: String(content).trim(), skills, links, image_url, likes: 0, created_at: new Date().toISOString() };
  db.posts.unshift(post);
  await writeDB(db);
  res.status(201).json({ post: { ...post, author } });
});

app.post('/api/posts/:postId/like', async (req, res) => {
  const db = await readDB();
  const post = (db.posts || []).find((item) => item.id === Number(req.params.postId));
  if (!post) return res.status(404).json({ error: 'Post not found' });
  post.likes = Number(post.likes || 0) + 1;
  await writeDB(db);
  res.json({ post });
});

// Backward-compatible profile update route used by the frontend.
app.put('/api/profiles/:wallet', async (req, res) => {
  req.url = `/api/users/${req.params.wallet}/profile`;
  return app._router.handle(req, res, () => undefined);
});

app.get('/api/access-requests', async (req, res) => {
  const db = await readDB();
  const wallet = String(req.query.wallet || '').toLowerCase();
  const user = db.users.find((item) => item.wallet_address.toLowerCase() === wallet);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const accessRequests = (db.access_requests || []).filter((item) => item.owner_id === user.id || item.requester_id === user.id).map((item) => ({ ...item, project: db.projects.find((project) => project.id === item.project_id), requester: db.users.find((person) => person.id === item.requester_id), owner: db.users.find((person) => person.id === item.owner_id) }));
  res.json({ accessRequests });
});

app.patch('/api/access-requests/:requestId', async (req, res) => {
  const { wallet, status } = req.body;
  if (!wallet || !['approved', 'rejected'].includes(status)) return res.status(400).json({ error: 'Owner wallet and valid status are required' });
  const db = await readDB();
  const owner = db.users.find((item) => item.wallet_address.toLowerCase() === String(wallet).toLowerCase());
  const request = (db.access_requests || []).find((item) => item.id === Number(req.params.requestId));
  if (!owner || !request || request.owner_id !== owner.id) return res.status(403).json({ error: 'Only the project owner can review this request' });
  request.status = status;
  request.reviewed_at = new Date().toISOString();
  await writeDB(db);
  res.json({ accessRequest: request });
});

app.post('/api/projects/:projectId/access-requests', async (req, res) => {
  const { wallet, message = '' } = req.body;
  if (!wallet) return res.status(400).json({ error: 'Wallet is required' });
  const db = await readDB();
  const projectId = Number(req.params.projectId);
  const project = db.projects.find((item) => item.id === projectId);
  const user = db.users.find((item) => item.wallet_address.toLowerCase() === String(wallet).toLowerCase());
  if (!project || !user) return res.status(404).json({ error: 'Project or user not found' });
  if (project.recruiter_id === user.id) return res.status(400).json({ error: 'Project owners cannot request their own access' });
  db.access_requests ||= [];
  const existing = db.access_requests.find((item) => item.project_id === projectId && item.requester_id === user.id && item.status === 'pending');
  if (existing) return res.json({ accessRequest: existing });
  const accessRequest = { id: db.access_requests.length + 1, project_id: projectId, owner_id: project.recruiter_id, requester_id: user.id, message, status: 'pending', created_at: new Date().toISOString() };
  db.access_requests.push(accessRequest);
  await writeDB(db);
  res.status(201).json({ accessRequest });
});

app.post('/api/connections', async (req, res) => {
  const { from_wallet, to_wallet } = req.body;
  if (!from_wallet || !to_wallet) return res.status(400).json({ error: 'Both wallets are required' });
  const db = await readDB();
  db.connections ||= [];
  const from = db.users.find((item) => item.wallet_address.toLowerCase() === String(from_wallet).toLowerCase());
  const to = db.users.find((item) => item.wallet_address.toLowerCase() === String(to_wallet).toLowerCase());
  if (!from || !to) return res.status(404).json({ error: 'User not found' });
  const existing = db.connections.find((item) => item.from_user_id === from.id && item.to_user_id === to.id);
  if (existing) return res.json({ connection: existing });
  const connection = { id: db.connections.length + 1, from_user_id: from.id, to_user_id: to.id, status: 'pending', created_at: new Date().toISOString() };
  db.connections.push(connection);
  await writeDB(db);
  res.status(201).json({ connection });
});

// Start server
app.listen(PORT, () => {
  console.log(`🚀 API Server running on http://localhost:${PORT}`);
  console.log(`📊 Health check: http://localhost:${PORT}/healthz`);
});
