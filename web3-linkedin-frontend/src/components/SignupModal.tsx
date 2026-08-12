import { useState } from 'react';
import { useAuth, UserRole } from '../hooks/useAuth';

export function SignupModal({ isOpen, onClose }: { isOpen: boolean; onClose: () => void }) {
  const { completeSignup, error } = useAuth();
  const [form, setForm] = useState({ name: '', email: '', role: 'developer' as UserRole });
  const [submitting, setSubmitting] = useState(false);
  if (!isOpen) return null;
  async function submit(event: React.FormEvent) { event.preventDefault(); setSubmitting(true); try { await completeSignup(form.email, form.name, form.role); onClose(); } finally { setSubmitting(false); } }
  return <div className="modal-backdrop"><form className="project-form" onSubmit={submit}><button type="button" className="close-button" onClick={onClose}>×</button><span className="eyebrow">WELCOME TO THE NETWORK</span><h2>Build your profile</h2><p className="muted">Your wallet becomes your portable professional identity.</p><label>Full name<input required value={form.name} onChange={(e) => setForm({ ...form, name: e.target.value })} placeholder="Alex Morgan" /></label><label>Email address<input required type="email" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} placeholder="alex@example.com" /></label><label>I'm joining as<select value={form.role} onChange={(e) => setForm({ ...form, role: e.target.value as UserRole })}><option value="developer">Developer / creator</option><option value="recruiter">Recruiter / client</option></select></label>{error && <div className="notice">{error}</div>}<button className="primary-button" disabled={submitting}>{submitting ? 'Verifying wallet...' : 'Create profile →'}</button><p className="muted">You will sign one free message to prove wallet ownership. No transaction or gas required.</p></form></div>;
}
