/**
 * Vigie Centre d'Appel - Serveur Express
 *
 * Application séparée de Vigie Billets, mais qui partage sa base de données (tickets_db) pour réutiliser
 * les employés déjà existants, et son JWT_SECRET (même variable d'environnement) pour qu'un jeton de
 * connexion émis par Billets soit valide ici aussi, sans nouveau système de compte.
 */
const express   = require('express');
const jwt       = require('jsonwebtoken');
const helmet    = require('helmet');
const rateLimit = require('express-rate-limit');
const path      = require('path');
const fs        = require('fs');
const https     = require('https');
const { v4: uuidv4 } = require('uuid');

const { pool } = require('./db');
const { initCallcenterCalls } = require('./callcenter-calls');

const app  = express();
const PORT = process.env.PORT || 3504;
const APP_VERSION = require('./package.json').version;

if (!process.env.JWT_SECRET) {
  console.error('❌ FATAL: JWT_SECRET requis (le même que Vigie Billets). Définissez la variable d\'environnement JWT_SECRET.');
  process.exit(1);
}
const JWT_SECRET = process.env.JWT_SECRET;

// Adresse de Vigie Billets, pour relayer la connexion (employeeNumber/password/2FA) sans dupliquer la
// logique de vérification de mot de passe ici - Centre d'Appel n'a pas sa propre table de comptes.
const BILLETS_URL = process.env.BILLETS_URL || 'http://localhost:3500';

app.set('trust proxy', process.env.TRUST_PROXY === '1' ? 1 : false);

app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc:  ["'self'"],
      scriptSrc:   ["'self'", "'unsafe-inline'"],
      scriptSrcAttr: ["'unsafe-inline'"],
      styleSrc:    ["'self'", "'unsafe-inline'", 'https://fonts.googleapis.com'],
      fontSrc:     ["'self'", 'https://fonts.gstatic.com'],
      imgSrc:      ["'self'", 'data:', 'blob:'],
      connectSrc:  ["'self'"],
      // Helmet ajoute cette directive par défaut : elle forcerait chaque fetch/XHR de la page (même en relatif,
      // même vers le même hôte) à passer en HTTPS, ce qui casse tout tant qu'aucun certificat n'est configuré
      // sur ce port (c'est ça qui causait "Failed to fetch" / net::ERR_SSL_PROTOCOL_ERROR juste en essayant de
      // se connecter depuis un autre poste, en HTTP normal).
      upgradeInsecureRequests: null,
    },
  },
  // HSTS est par hôte : si activé, il forcerait http://hôte:3504 à passer en HTTPS après une seule visite,
  // ce qui casse tout tant qu'aucun certificat n'est configuré sur ce port (même piège déjà rencontré sur Billets).
  hsts: false,
}));
app.use(express.json({ limit: '1mb' }));

app.use(rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 10000,
  validate: { xForwardedForHeader: false },
}));
const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 150,
  message: { error: 'Trop de tentatives de connexion - réessayez dans 15 minutes.' },
  standardHeaders: true,
  legacyHeaders: false,
  validate: { xForwardedForHeader: false },
});

// ═════════════════════════════════════════════════════════════════════════════
// AUTH
// ═════════════════════════════════════════════════════════════════════════════
function auth(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'Token manquant' });
  try { req.user = jwt.verify(token, JWT_SECRET); next(); }
  catch { res.status(401).json({ error: 'Token invalide ou expiré' }); }
}
async function hasPermission(role, perm) {
  if (role === 'admin') return true;
  try {
    const r = await pool.query('SELECT allowed FROM role_permissions WHERE role=$1 AND permission=$2', [role, perm]);
    return r.rows[0]?.allowed || false;
  } catch (e) { console.error('Permission check error:', e.message); return false; }
}

// Relais de connexion vers Vigie Billets : Centre d'Appel n'a pas de mot de passe à lui, le jeton renvoyé
// par Billets (même JWT_SECRET) est directement accepté par le middleware auth() ci-dessus.
app.post('/api/login', loginLimiter, async (req, res) => {
  try {
    const r = await fetch(`${BILLETS_URL}/api/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req.body || {}),
    });
    const data = await r.json().catch(() => ({}));
    res.status(r.status).json(data);
  } catch (e) {
    console.error('Relais connexion vers Billets:', e.message);
    res.status(502).json({ error: 'Impossible de joindre Vigie Billets pour la connexion' });
  }
});

// ── Numéros de poste : table propre à Centre d'Appel (ne touche pas employees, qui appartient à Billets) ──
const EXTENSIONS_MIGRATION_SQL = `
  CREATE TABLE IF NOT EXISTS callcenter_extensions (
    employeeid UUID PRIMARY KEY REFERENCES employees(id) ON DELETE CASCADE,
    extension TEXT NOT NULL UNIQUE
  );
`;
async function migrateExtensions() {
  for (let attempt = 1; attempt <= 6; attempt++) {
    try { await pool.query(EXTENSIONS_MIGRATION_SQL); return; }
    catch (e) { if (attempt === 6) { console.warn('Migration postes:', e.message); return; } await new Promise(r => setTimeout(r, 2000 * attempt)); }
  }
}
const extensionsReady = migrateExtensions();

// Annuaire des employés pouvant être appelés (présence en temps réel via /api/callcenter/stream)
app.get('/api/callcenter/employees', auth, async (req, res) => {
  try {
    await extensionsReady;
    const r = await pool.query(
      `SELECT e.id, e.name, e.role, e.techlevel AS "techLevel", x.extension
       FROM employees e LEFT JOIN callcenter_extensions x ON x.employeeid = e.id
       ORDER BY e.name`
    );
    res.json(r.rows);
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// Chacun choisit son propre numéro de poste (pas d'écran d'admin pour ça en phase 1)
app.put('/api/callcenter/extension', auth, async (req, res) => {
  try {
    await extensionsReady;
    const extension = String((req.body || {}).extension || '').trim();
    if (!/^[0-9]{2,6}$/.test(extension)) return res.status(400).json({ error: 'Le numéro de poste doit contenir entre 2 et 6 chiffres' });
    await pool.query(
      `INSERT INTO callcenter_extensions (employeeid, extension) VALUES ($1,$2)
       ON CONFLICT (employeeid) DO UPDATE SET extension=$2`,
      [req.user.id, extension]
    );
    res.json({ extension });
  } catch (e) {
    if (e.code === '23505') return res.status(409).json({ error: 'Ce numéro de poste est déjà pris par quelqu\'un d\'autre' });
    console.error(e); res.status(500).json({ error: 'Erreur serveur' });
  }
});

app.get('/api/version', (req, res) => res.json({ version: APP_VERSION }));

// ── Appels internes (voir callcenter-calls.js) : avant la route "toutes les autres pages" ──
initCallcenterCalls({ app, pool, auth, hasPermission, uuidv4 });

app.use(express.static(__dirname, { index: false }));
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

app.use((err, req, res, next) => {
  console.error('Erreur non gérée:', err);
  res.status(500).json({ error: 'Erreur serveur' });
});

// ── HTTPS interne, en parallèle du HTTP (même principe que Vigie Billets : le micro exige HTTPS hors localhost) ──
const HTTPS_PORT = parseInt(process.env.HTTPS_PORT || '3505', 10);
const CERT_DIR = process.env.CERT_DIR || path.join(__dirname, 'certs');
function loadTlsOptions() {
  try {
    const pfx = path.join(CERT_DIR, 'vigie.pfx');
    if (fs.existsSync(pfx)) {
      const passFile = path.join(CERT_DIR, 'pfx-pass.txt');
      const passphrase = process.env.CERT_PASSPHRASE || (fs.existsSync(passFile) ? fs.readFileSync(passFile, 'utf8').trim() : '');
      return { pfx: fs.readFileSync(pfx), passphrase, minVersion: 'TLSv1.2' };
    }
    const key = path.join(CERT_DIR, 'vigie.key'), crt = path.join(CERT_DIR, 'vigie.crt');
    if (fs.existsSync(key) && fs.existsSync(crt)) return { key: fs.readFileSync(key), cert: fs.readFileSync(crt), minVersion: 'TLSv1.2' };
  } catch (e) { console.warn('Certificat HTTPS illisible:', e.message); }
  return null;
}
const TLS_OPTIONS = loadTlsOptions();

app.listen(PORT, () => {
  console.log(`🚀 Vigie Centre d'Appel lancé sur http://localhost:${PORT}`);
});

if (TLS_OPTIONS) {
  const httpsServer = https.createServer(TLS_OPTIONS, app);
  httpsServer.on('error', e => console.warn('HTTPS non démarré:', e.message));
  httpsServer.on('tlsClientError', e => console.warn('HTTPS, connexion refusée (poignée de main TLS) :', e.message));
  httpsServer.listen(HTTPS_PORT, () => console.log(`🔒 HTTPS interne sur https://localhost:${HTTPS_PORT}`));
}
