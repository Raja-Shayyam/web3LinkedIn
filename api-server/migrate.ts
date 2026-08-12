import { createWriteStream } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { pipeline } from 'stream/promises';
import { mkdir } from 'fs/promises';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Simple file-based database mock for development
// In production, replace with actual PostgreSQL/MySQL
const dbPath = join(__dirname, 'data');
const dataFile = join(dbPath, 'db.json');

console.log('🗄️  Initializing database...');

// Initialize data structure
const initialData = {
  users: [
    {
      id: 1,
      google_id: 'sample-google-id-1',
      email: 'recruiter@example.com',
      name: 'Alice Recruiter',
      wallet_address: '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
      role: 'recruiter',
      created_at: new Date().toISOString()
    },
    {
      id: 2,
      google_id: 'sample-google-id-2',
      email: 'developer@example.com',
      name: 'Bob Developer',
      wallet_address: '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC',
      role: 'developer',
      created_at: new Date().toISOString()
    }
  ],
  profiles: [],
  projects: [],
  milestones: [],
  endorsements: [],
  nonces: []
};

async function initDB() {
  try {
    await mkdir(dbPath, { recursive: true });
    
    // Check if data file exists
    const fs = await import('fs/promises');
    let exists = true;
    try {
      await fs.access(dataFile);
    } catch {
      exists = false;
    }
    
    if (!exists) {
      // Write initial data
      await fs.writeFile(dataFile, JSON.stringify(initialData, null, 2));
      console.log('✅ Database initialized with sample data!');
    } else {
      console.log('✅ Database already exists!');
    }
    
    console.log(`📁 Data location: ${dataFile}`);
    console.log('🎉 Migration complete!');
  } catch (err) {
    console.error('❌ Error initializing database:', err);
  }
}

initDB();
