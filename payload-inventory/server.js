const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { v4: uuidv4 } = require('uuid');
const path = require('path');
const { pool } = require('./db.js');

if (!process.env.JWT_SECRET) {
  console.error('❌ FATAL: JWT_SECRET requis. Définissez la variable d\'environnement JWT_SECRET.');
  process.exit(1);
}
const JWT_SECRET = process.env.JWT_SECRET;
const PORT = process.env.PORT || 3502;

const app = express();
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'", 'https://fonts.googleapis.com'],
      fontSrc: ["'self'", 'https://fonts.gstatic.com'],
      scriptSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", 'data:'],
      upgradeInsecureRequests: null
    }
  }
}));
app.use(express.json());
// Sert UNIQUEMENT public/ (index.html + brand/) — jamais server.js, db.js,
// node_modules, _setup/, ni les fichiers écrits par l'installateur
// (IMPORTANT - Identifiants.txt, install-log.txt, service-*.log) qui
// contiennent des secrets et ne doivent jamais être accessibles par HTTP.
app.use(express.static(path.join(__dirname, 'public'), { index: 'index.html' }));

// Calibré pour une moyenne entreprise : la limite est par IP, pas par
// personne — plusieurs employés derrière la même passerelle réseau
// partagent le même compteur et peuvent se bloquer mutuellement si le
// seuil est trop bas. Le vrai frein contre un bruteforce reste bcrypt.
const loginLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 150, standardHeaders: true, legacyHeaders: false });

// ═════════════════════════════════════════════════════════════════════════════
// MIGRATIONS — Vigie Inventory est un produit autonome : sa propre base de
// données, ses propres comptes, aucune dépendance à Vigie Billets/Vigie Parc.
// Catégories, départements et champs personnalisés sont gérables par un admin
// (page Paramètres) pour que n'importe quelle entreprise adapte l'outil à son
// matériel (ordinateurs, outils, véhicules, équipement de cuisine…).
// ═════════════════════════════════════════════════════════════════════════════
async function migrate() {
  await pool.query(`CREATE EXTENSION IF NOT EXISTS "uuid-ossp";`);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS employees (
      id                 UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
      employeenumber     TEXT        NOT NULL UNIQUE,
      name               TEXT        NOT NULL,
      role               TEXT        NOT NULL DEFAULT 'employee' CHECK (role IN ('employee','gestionnaire','admin')),
      password           TEXT        NOT NULL,
      mustchangepassword BOOLEAN     NOT NULL DEFAULT true,
      createdat          TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS categories (
      id        UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
      name      TEXT        NOT NULL UNIQUE,
      code      TEXT        NOT NULL,
      createdat TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS departments (
      id        UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
      name      TEXT        NOT NULL UNIQUE,
      code      TEXT        NOT NULL,
      createdat TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS custom_fields (
      id        UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
      label     TEXT        NOT NULL UNIQUE,
      fieldtype TEXT        NOT NULL DEFAULT 'text' CHECK (fieldtype IN ('text','number','date')),
      createdat TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS assets (
      id               UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
      type             TEXT        NOT NULL,
      brand            TEXT,
      model            TEXT,
      serialnumber     TEXT,
      warrantyuntil    DATE,
      quantity         INTEGER     NOT NULL DEFAULT 1,
      purchaseprice    NUMERIC(10,2),
      saleprice        NUMERIC(10,2),
      location         TEXT,
      department       TEXT,
      tag              TEXT,
      customfields     JSONB       NOT NULL DEFAULT '{}'::jsonb,
      notes            TEXT,
      createdby        UUID        REFERENCES employees(id) ON DELETE SET NULL,
      createdat        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updatedat        TIMESTAMPTZ,
      warrantynotified BOOLEAN     NOT NULL DEFAULT false
    );
    ALTER TABLE assets ADD COLUMN IF NOT EXISTS customfields   JSONB NOT NULL DEFAULT '{}'::jsonb;
    ALTER TABLE assets ADD COLUMN IF NOT EXISTS purchaseprice  NUMERIC(10,2);
    ALTER TABLE assets ADD COLUMN IF NOT EXISTS saleprice      NUMERIC(10,2);
    ALTER TABLE assets ADD COLUMN IF NOT EXISTS quantity       INTEGER NOT NULL DEFAULT 1;
    CREATE INDEX IF NOT EXISTS idx_assets_type   ON assets(type);

    CREATE TABLE IF NOT EXISTS vendors (
      id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
      name        TEXT        NOT NULL,
      contactname TEXT,
      phone       TEXT,
      email       TEXT,
      address     TEXT,
      city        TEXT,
      province    TEXT,
      postal      TEXT,
      notes       TEXT,
      createdby   UUID        REFERENCES employees(id) ON DELETE SET NULL,
      createdat   TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS contracts (
      id             UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
      title          TEXT        NOT NULL,
      type           TEXT        NOT NULL DEFAULT 'entretien'
                                  CHECK (type IN ('garantie','entretien','location','support','autre')),
      vendorid       UUID        REFERENCES vendors(id) ON DELETE SET NULL,
      startdate      DATE,
      enddate        DATE,
      cost           NUMERIC(10,2),
      coveredassets  TEXT,
      notes          TEXT,
      createdby      UUID        REFERENCES employees(id) ON DELETE SET NULL,
      createdat      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      expirynotified BOOLEAN     NOT NULL DEFAULT false
    );
    CREATE INDEX IF NOT EXISTS idx_contracts_enddate ON contracts(enddate);

    CREATE TABLE IF NOT EXISTS notifications (
      id          UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
      recipientid UUID        NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
      body        TEXT        NOT NULL,
      isread      BOOLEAN     NOT NULL DEFAULT false,
      createdat   TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS idx_notif_recipient ON notifications(recipientid, createdat DESC);

    CREATE TABLE IF NOT EXISTS role_permissions (
      role       TEXT    NOT NULL,
      permission TEXT    NOT NULL,
      allowed    BOOLEAN NOT NULL DEFAULT false,
      PRIMARY KEY (role, permission)
    );
  `);

  await pool.query(`
    INSERT INTO role_permissions (role, permission, allowed) VALUES
      ('gestionnaire','manage_assets',true),
      ('gestionnaire','manage_vendors',true), ('gestionnaire','manage_contracts',true),
      ('employee','manage_assets',true),
      ('employee','manage_vendors',false), ('employee','manage_contracts',false)
    ON CONFLICT (role,permission) DO NOTHING;
  `);

  // Compte admin par défaut si aucun compte n'existe encore
  const existing = await pool.query('SELECT COUNT(*) AS c FROM employees');
  if (parseInt(existing.rows[0].c, 10) === 0) {
    const hash = bcrypt.hashSync('Admin1234!', 12);
    await pool.query(
      'INSERT INTO employees (id, employeenumber, name, role, password, mustchangepassword) VALUES ($1,$2,$3,$4,$5,$6)',
      [uuidv4(), 'ADMIN001', 'Administrateur', 'admin', hash, true]
    );
    console.log('👤 Compte admin par défaut créé — ADMIN001 / Admin1234! (à changer à la première connexion)');
  }

  // Catégories de matériel par défaut si aucune n'existe encore (typiques
  // d'un parc informatique — entièrement modifiables/remplaçables ensuite
  // par un admin selon le domaine de l'entreprise : outils, véhicules,
  // équipement de cuisine, matériel médical…).
  const catExisting = await pool.query('SELECT COUNT(*) AS c FROM categories');
  if (parseInt(catExisting.rows[0].c, 10) === 0) {
    const defaultCats = [
      ['Ordinateur portable','P'], ['Ordinateur de bureau','B'], ['Imprimante','IMP'],
      ['Écran','ECR'], ['Téléphone','TEL'], ['Tablette','TAB'], ['Routeur','RTR'], ['Serveur','SRV']
    ];
    for (const [name, code] of defaultCats) {
      await pool.query('INSERT INTO categories (id, name, code) VALUES ($1,$2,$3)', [uuidv4(), name, code]);
    }
  }

  // Départements par défaut si aucun n'existe encore (modifiables ensuite par un admin)
  const deptExisting = await pool.query('SELECT COUNT(*) AS c FROM departments');
  if (parseInt(deptExisting.rows[0].c, 10) === 0) {
    const defaultDepts = [['RH','RH'],['TI','TI'],['Comptabilité','COMPTA'],['Ventes','VTE'],['Direction','DIR'],['Production','PROD']];
    for (const [name, code] of defaultDepts) {
      await pool.query('INSERT INTO departments (id, name, code) VALUES ($1,$2,$3)', [uuidv4(), name, code]);
    }
  }

  console.log('✅ Migrations Vigie Inventory appliquées.');
}

// ═════════════════════════════════════════════════════════════════════════════
// AUTH
// ═════════════════════════════════════════════════════════════════════════════
function auth(req, res, next) {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'Token manquant' });
  try {
    req.user = jwt.verify(token, JWT_SECRET, { algorithms: ['HS256'] });
    next();
  } catch { res.status(401).json({ error: 'Token invalide ou expiré' }); }
}
function adminOnly(req, res, next) {
  if (req.user?.role !== 'admin') return res.status(403).json({ error: 'Accès réservé aux administrateurs' });
  next();
}

// ═════════════════════════════════════════════════════════════════════════════
// PERMISSIONS PAR RÔLE — admin a toujours tout ; technicien/superviseur
// configurables par un admin (page Paramètres)
// ═════════════════════════════════════════════════════════════════════════════
const PERMISSION_KEYS = ['manage_assets', 'manage_vendors', 'manage_contracts'];
async function hasPermission(role, perm) {
  if (role === 'admin') return true;
  try {
    const r = await pool.query('SELECT allowed FROM role_permissions WHERE role=$1 AND permission=$2', [role, perm]);
    return r.rows[0]?.allowed || false;
  } catch (e) { console.error('Permission check error:', e.message); return false; }
}
function requirePermission(perm) {
  return async (req, res, next) => {
    if (await hasPermission(req.user?.role, perm)) return next();
    res.status(403).json({ error: 'Accès refusé' });
  };
}

app.post('/api/login', loginLimiter, async (req, res) => {
  try {
    const { employeeNumber, password } = req.body;
    if (!employeeNumber || !password)
      return res.status(400).json({ error: 'Champs requis manquants' });

    const result = await pool.query('SELECT * FROM employees WHERE employeenumber = $1', [employeeNumber]);
    const emp = result.rows[0];
    if (!emp || !bcrypt.compareSync(password, emp.password))
      return res.status(401).json({ error: 'Numéro ou mot de passe incorrect' });

    const token = jwt.sign(
      { id: emp.id, name: emp.name, role: emp.role, employeeNumber: emp.employeenumber },
      JWT_SECRET, { expiresIn: '8h' }
    );
    res.json({
      token,
      user: { id: emp.id, name: emp.name, role: emp.role, employeeNumber: emp.employeenumber, mustChangePassword: emp.mustchangepassword }
    });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.put('/api/change-password', auth, async (req, res) => {
  try {
    const { currentPassword, newPassword } = req.body;
    if (!newPassword || newPassword.length < 8) return res.status(400).json({ error: 'Le mot de passe doit contenir au moins 8 caractères' });
    const result = await pool.query('SELECT password, mustchangepassword FROM employees WHERE id=$1', [req.user.id]);
    const emp = result.rows[0];
    if (!emp) return res.status(404).json({ error: 'Compte introuvable' });
    // Le changement forcé à la première connexion n'exige pas l'ancien mot de
    // passe temporaire (l'utilisateur vient de le saisir pour se connecter) ;
    // tout changement volontaire ultérieur doit reconfirmer le mot de passe
    // actuel pour empêcher un jeton volé de verrouiller le compte légitime.
    if (!emp.mustchangepassword) {
      if (!currentPassword || !bcrypt.compareSync(currentPassword, emp.password))
        return res.status(401).json({ error: 'Mot de passe actuel incorrect' });
    }
    const hash = bcrypt.hashSync(newPassword, 12);
    await pool.query('UPDATE employees SET password=$1, mustchangepassword=false WHERE id=$2', [hash, req.user.id]);
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// ÉQUIPE — gestion complète réservée aux admins
// ═════════════════════════════════════════════════════════════════════════════
app.get('/api/employees', auth, async (req, res) => {
  try {
    const r = await pool.query('SELECT id, name, employeenumber, role FROM employees ORDER BY name ASC');
    res.json(r.rows.map(e => ({ id: e.id, name: e.name, employeeNumber: e.employeenumber, role: e.role })));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.post('/api/employees', auth, adminOnly, async (req, res) => {
  try {
    const { employeeNumber, name, role, password } = req.body;
    if (!employeeNumber || !name || !password) return res.status(400).json({ error: 'Champs requis manquants' });
    if (!['employee','gestionnaire','admin'].includes(role)) return res.status(400).json({ error: 'Rôle invalide' });
    const existing = await pool.query('SELECT id FROM employees WHERE employeenumber=$1', [employeeNumber]);
    if (existing.rows[0]) return res.status(400).json({ error: 'Ce numéro d\'employé existe déjà' });
    const id = uuidv4();
    const hash = bcrypt.hashSync(password, 12);
    await pool.query(
      'INSERT INTO employees (id, employeenumber, name, role, password, mustchangepassword) VALUES ($1,$2,$3,$4,$5,true)',
      [id, employeeNumber, name, role, hash]
    );
    res.json({ id, employeeNumber, name, role });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.put('/api/employees/:id', auth, adminOnly, async (req, res) => {
  try {
    const { name, role, password } = req.body;
    if (!['employee','gestionnaire','admin'].includes(role)) return res.status(400).json({ error: 'Rôle invalide' });
    if (password) {
      const hash = bcrypt.hashSync(password, 12);
      await pool.query('UPDATE employees SET name=$1, role=$2, password=$3, mustchangepassword=true WHERE id=$4', [name, role, hash, req.params.id]);
    } else {
      await pool.query('UPDATE employees SET name=$1, role=$2 WHERE id=$3', [name, role, req.params.id]);
    }
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.delete('/api/employees/:id', auth, adminOnly, async (req, res) => {
  try {
    if (req.params.id === req.user.id) return res.status(400).json({ error: 'Vous ne pouvez pas supprimer votre propre compte' });
    await pool.query('DELETE FROM employees WHERE id=$1', [req.params.id]);
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// PERMISSIONS
// ═════════════════════════════════════════════════════════════════════════════
app.get('/api/my-permissions', auth, async (req, res) => {
  try {
    if (req.user.role === 'admin') {
      const all = {}; PERMISSION_KEYS.forEach(k => all[k] = true);
      return res.json(all);
    }
    const r = await pool.query('SELECT permission, allowed FROM role_permissions WHERE role=$1', [req.user.role]);
    const perms = {}; PERMISSION_KEYS.forEach(k => perms[k] = false);
    r.rows.forEach(row => { perms[row.permission] = row.allowed; });
    res.json(perms);
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.get('/api/permissions', auth, adminOnly, async (req, res) => {
  try {
    const r = await pool.query('SELECT role, permission, allowed FROM role_permissions');
    res.json(r.rows);
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.put('/api/permissions', auth, adminOnly, async (req, res) => {
  try {
    const { role, permission, allowed } = req.body;
    if (!['employee','gestionnaire'].includes(role)) return res.status(400).json({ error: 'Rôle invalide' });
    if (!PERMISSION_KEYS.includes(permission)) return res.status(400).json({ error: 'Permission invalide' });
    await pool.query(
      `INSERT INTO role_permissions (role, permission, allowed) VALUES ($1,$2,$3)
       ON CONFLICT (role,permission) DO UPDATE SET allowed=$3`,
      [role, permission, !!allowed]
    );
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// CATÉGORIES — types de matériel, personnalisables selon le domaine de
// l'entreprise (informatique, outils, véhicules, cuisine…)
// ═════════════════════════════════════════════════════════════════════════════
app.get('/api/categories', auth, async (req, res) => {
  try {
    const r = await pool.query('SELECT id, name, code FROM categories ORDER BY name ASC');
    res.json(r.rows);
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.post('/api/categories', auth, adminOnly, async (req, res) => {
  try {
    const { name, code } = req.body;
    if (!name || !code) return res.status(400).json({ error: 'Nom et code sont obligatoires' });
    const id = uuidv4();
    await pool.query('INSERT INTO categories (id, name, code) VALUES ($1,$2,$3)', [id, name.trim(), code.trim().toUpperCase()]);
    res.json({ id, name: name.trim(), code: code.trim().toUpperCase() });
  } catch (e) {
    if (e.code === '23505') return res.status(400).json({ error: 'Cette catégorie existe déjà' });
    console.error(e); res.status(500).json({ error: 'Erreur serveur' });
  }
});
app.put('/api/categories/:id', auth, adminOnly, async (req, res) => {
  try {
    const { name, code } = req.body;
    if (!name || !code) return res.status(400).json({ error: 'Nom et code sont obligatoires' });
    await pool.query('UPDATE categories SET name=$1, code=$2 WHERE id=$3', [name.trim(), code.trim().toUpperCase(), req.params.id]);
    res.json({ success: true });
  } catch (e) {
    if (e.code === '23505') return res.status(400).json({ error: 'Cette catégorie existe déjà' });
    console.error(e); res.status(500).json({ error: 'Erreur serveur' });
  }
});
app.delete('/api/categories/:id', auth, adminOnly, async (req, res) => {
  try {
    await pool.query('DELETE FROM categories WHERE id=$1', [req.params.id]);
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// DÉPARTEMENTS — catalogue utilisé par le générateur de code d'inventaire
// ═════════════════════════════════════════════════════════════════════════════
app.get('/api/departments', auth, async (req, res) => {
  try {
    const r = await pool.query('SELECT id, name, code FROM departments ORDER BY name ASC');
    res.json(r.rows);
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.post('/api/departments', auth, adminOnly, async (req, res) => {
  try {
    const { name, code } = req.body;
    if (!name || !code) return res.status(400).json({ error: 'Nom et code sont obligatoires' });
    const id = uuidv4();
    await pool.query('INSERT INTO departments (id, name, code) VALUES ($1,$2,$3)', [id, name.trim(), code.trim().toUpperCase()]);
    res.json({ id, name: name.trim(), code: code.trim().toUpperCase() });
  } catch (e) {
    if (e.code === '23505') return res.status(400).json({ error: 'Ce département existe déjà' });
    console.error(e); res.status(500).json({ error: 'Erreur serveur' });
  }
});
app.put('/api/departments/:id', auth, adminOnly, async (req, res) => {
  try {
    const { name, code } = req.body;
    if (!name || !code) return res.status(400).json({ error: 'Nom et code sont obligatoires' });
    await pool.query('UPDATE departments SET name=$1, code=$2 WHERE id=$3', [name.trim(), code.trim().toUpperCase(), req.params.id]);
    res.json({ success: true });
  } catch (e) {
    if (e.code === '23505') return res.status(400).json({ error: 'Ce département existe déjà' });
    console.error(e); res.status(500).json({ error: 'Erreur serveur' });
  }
});
app.delete('/api/departments/:id', auth, adminOnly, async (req, res) => {
  try {
    await pool.query('DELETE FROM departments WHERE id=$1', [req.params.id]);
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// CHAMPS PERSONNALISÉS — définitions ajoutées par l'admin (ex. "Kilométrage"
// pour un véhicule, "Date de calibration" pour un outil). Les valeurs sont
// stockées par article dans assets.customfields (JSONB), indexées par label.
// ═════════════════════════════════════════════════════════════════════════════
app.get('/api/custom-fields', auth, async (req, res) => {
  try {
    const r = await pool.query('SELECT id, label, fieldtype FROM custom_fields ORDER BY createdat ASC');
    res.json(r.rows.map(f => ({ id: f.id, label: f.label, fieldType: f.fieldtype })));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.post('/api/custom-fields', auth, adminOnly, async (req, res) => {
  try {
    const { label, fieldType } = req.body;
    if (!label) return res.status(400).json({ error: 'Le nom du champ est obligatoire' });
    if (!['text','number','date'].includes(fieldType)) return res.status(400).json({ error: 'Type de champ invalide' });
    const id = uuidv4();
    await pool.query('INSERT INTO custom_fields (id, label, fieldtype) VALUES ($1,$2,$3)', [id, label.trim(), fieldType]);
    res.json({ id, label: label.trim(), fieldType });
  } catch (e) {
    if (e.code === '23505') return res.status(400).json({ error: 'Ce champ existe déjà' });
    console.error(e); res.status(500).json({ error: 'Erreur serveur' });
  }
});
app.delete('/api/custom-fields/:id', auth, adminOnly, async (req, res) => {
  try {
    await pool.query('DELETE FROM custom_fields WHERE id=$1', [req.params.id]);
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// INVENTAIRE
// ═════════════════════════════════════════════════════════════════════════════
function hydrateAsset(a) {
  return {
    id: a.id, type: a.type, brand: a.brand, model: a.model, serialNumber: a.serialnumber,
    warrantyUntil: a.warrantyuntil,
    quantity: a.quantity != null ? parseInt(a.quantity, 10) : 1,
    purchasePrice: a.purchaseprice != null ? parseFloat(a.purchaseprice) : null,
    salePrice: a.saleprice != null ? parseFloat(a.saleprice) : null,
    location: a.location, department: a.department, tag: a.tag,
    customFields: a.customfields || {}, notes: a.notes,
    createdBy: a.createdby, createdByName: a.createdbyname || null,
    createdAt: a.createdat, updatedAt: a.updatedat
  };
}

const ASSET_SELECT = `
  SELECT a.*, cb.name AS createdbyname
  FROM assets a
  LEFT JOIN employees cb ON a.createdby = cb.id
`;

app.get('/api/assets', auth, async (req, res) => {
  try {
    const { search } = req.query;
    let query = ASSET_SELECT + ' WHERE 1=1';
    const params = [];
    if (search) {
      params.push(`%${search}%`);
      query += ` AND (a.type ILIKE $${params.length} OR a.brand ILIKE $${params.length} OR a.model ILIKE $${params.length} OR a.serialnumber ILIKE $${params.length})`;
    }
    query += ' ORDER BY a.createdat DESC';
    const r = await pool.query(query, params);
    res.json(r.rows.map(hydrateAsset));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// Suggère le prochain numéro d'inventaire pour un préfixe donné (ex. "PDELL-RH-")
// en cherchant le plus grand suffixe numérique déjà utilisé parmi les tags existants.
// Doit être déclaré AVANT /api/assets/:id, sinon Express route "next-tag" vers :id.
app.get('/api/assets/next-tag', auth, async (req, res) => {
  try {
    const prefix = (req.query.prefix || '').trim();
    if (!prefix) return res.json({ tag: '' });
    const r = await pool.query(`SELECT tag FROM assets WHERE tag ILIKE $1 || '%'`, [prefix]);
    let max = 0;
    const re = new RegExp('^' + prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(\\d+)$', 'i');
    r.rows.forEach(row => {
      const m = row.tag && row.tag.match(re);
      if (m) max = Math.max(max, parseInt(m[1], 10));
    });
    const next = String(max + 1).padStart(3, '0');
    res.json({ tag: prefix + next });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// Recherche exacte par code scanné (douchette/scanner Bluetooth = clavier) —
// cherche d'abord le code d'inventaire généré, sinon le numéro de série du
// fabricant (utile si l'appareil a déjà son propre code-barres imprimé).
app.get('/api/assets/scan', auth, async (req, res) => {
  try {
    const code = (req.query.code || '').trim();
    if (!code) return res.status(400).json({ error: 'Code requis' });
    const r = await pool.query(ASSET_SELECT + ' WHERE a.tag ILIKE $1 OR a.serialnumber ILIKE $1 LIMIT 1', [code]);
    if (!r.rows[0]) return res.status(404).json({ error: 'Aucun article trouvé avec ce code' });
    res.json(hydrateAsset(r.rows[0]));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.get('/api/assets/:id', auth, async (req, res) => {
  try {
    const r = await pool.query(ASSET_SELECT + ' WHERE a.id=$1', [req.params.id]);
    if (!r.rows[0]) return res.status(404).json({ error: 'Article introuvable' });
    res.json(hydrateAsset(r.rows[0]));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.post('/api/assets', auth, requirePermission('manage_assets'), async (req, res) => {
  try {
    const { type, brand, model, serialNumber, warrantyUntil, quantity, purchasePrice, salePrice, location, department, tag, customFields, notes } = req.body;
    if (!type) return res.status(400).json({ error: 'Le type est obligatoire' });
    const id = uuidv4();
    await pool.query(`
      INSERT INTO assets (id, type, brand, model, serialnumber, warrantyuntil, quantity, purchaseprice, saleprice, location, department, tag, customfields, notes, createdby, createdat)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,NOW())
    `, [id, type, brand || null, model || null, serialNumber || null,
        warrantyUntil || null, parseInt(quantity, 10) || 1, purchasePrice || null, salePrice || null, location || null,
        department || null, tag || null, JSON.stringify(customFields && typeof customFields === 'object' ? customFields : {}),
        notes || null, req.user.id]);
    const r = await pool.query(ASSET_SELECT + ' WHERE a.id=$1', [id]);
    res.json(hydrateAsset(r.rows[0]));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.put('/api/assets/:id', auth, requirePermission('manage_assets'), async (req, res) => {
  try {
    const { type, brand, model, serialNumber, warrantyUntil, quantity, purchasePrice, salePrice, location, department, tag, customFields, notes } = req.body;
    const existing = await pool.query('SELECT id FROM assets WHERE id=$1', [req.params.id]);
    if (!existing.rows[0]) return res.status(404).json({ error: 'Article introuvable' });
    await pool.query(`
      UPDATE assets SET
        type=$1, brand=$2, model=$3, serialnumber=$4, warrantyuntil=$5,
        quantity=$6, purchaseprice=$7, saleprice=$8, location=$9, department=$10, tag=$11, customfields=$12, notes=$13, updatedat=NOW()
      WHERE id=$14
    `, [type, brand || null, model || null, serialNumber || null,
        warrantyUntil || null, parseInt(quantity, 10) || 1, purchasePrice || null, salePrice || null, location || null,
        department || null, tag || null, JSON.stringify(customFields && typeof customFields === 'object' ? customFields : {}),
        notes || null, req.params.id]);
    const r = await pool.query(ASSET_SELECT + ' WHERE a.id=$1', [req.params.id]);
    res.json(hydrateAsset(r.rows[0]));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.delete('/api/assets/:id', auth, requirePermission('manage_assets'), async (req, res) => {
  try {
    await pool.query('DELETE FROM assets WHERE id=$1', [req.params.id]);
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// FOURNISSEURS
// ═════════════════════════════════════════════════════════════════════════════
function hydrateVendor(v) {
  return { id: v.id, name: v.name, contactName: v.contactname, phone: v.phone, email: v.email, address: v.address, city: v.city, province: v.province, postal: v.postal, notes: v.notes, createdAt: v.createdat };
}
app.get('/api/vendors', auth, async (req, res) => {
  try {
    const r = await pool.query('SELECT * FROM vendors ORDER BY name ASC');
    res.json(r.rows.map(hydrateVendor));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.post('/api/vendors', auth, requirePermission('manage_vendors'), async (req, res) => {
  try {
    const { name, contactName, phone, email, address, city, province, postal, notes } = req.body;
    if (!name) return res.status(400).json({ error: 'Le nom est obligatoire' });
    const id = uuidv4();
    await pool.query(
      'INSERT INTO vendors (id, name, contactname, phone, email, address, city, province, postal, notes, createdby, createdat) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,NOW())',
      [id, name, contactName || null, phone || null, email || null, address || null, city || null, province || null, postal || null, notes || null, req.user.id]
    );
    const r = await pool.query('SELECT * FROM vendors WHERE id=$1', [id]);
    res.json(hydrateVendor(r.rows[0]));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.put('/api/vendors/:id', auth, requirePermission('manage_vendors'), async (req, res) => {
  try {
    const { name, contactName, phone, email, address, city, province, postal, notes } = req.body;
    await pool.query(
      'UPDATE vendors SET name=$1, contactname=$2, phone=$3, email=$4, address=$5, city=$6, province=$7, postal=$8, notes=$9 WHERE id=$10',
      [name, contactName || null, phone || null, email || null, address || null, city || null, province || null, postal || null, notes || null, req.params.id]
    );
    const r = await pool.query('SELECT * FROM vendors WHERE id=$1', [req.params.id]);
    if (!r.rows[0]) return res.status(404).json({ error: 'Fournisseur introuvable' });
    res.json(hydrateVendor(r.rows[0]));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.delete('/api/vendors/:id', auth, requirePermission('manage_vendors'), async (req, res) => {
  try {
    await pool.query('DELETE FROM vendors WHERE id=$1', [req.params.id]);
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// GÉOCODAGE — suggestions d'adresses (OpenStreetMap Nominatim, gratuit, sans clé)
// ═════════════════════════════════════════════════════════════════════════════
const PROVINCE_CODES = {
  'quebec': 'QC', 'québec': 'QC', 'ontario': 'ON', 'british columbia': 'BC',
  'alberta': 'AB', 'manitoba': 'MB', 'saskatchewan': 'SK', 'nova scotia': 'NS',
  'new brunswick': 'NB', 'newfoundland and labrador': 'NL', 'prince edward island': 'PE',
};

app.get('/api/geocode/suggest', auth, async (req, res) => {
  try {
    const q = (req.query.q || '').trim();
    if (q.length < 4) return res.json([]);

    const url = 'https://nominatim.openstreetmap.org/search?' + new URLSearchParams({
      q, format: 'json', addressdetails: '1', countrycodes: 'ca', limit: '5'
    });
    const r = await fetch(url, { headers: { 'User-Agent': 'Vigie-Inventory/1.0 (usage interne)' } });
    if (!r.ok) return res.json([]);

    const data = await r.json();
    const suggestions = data.map(item => {
      const a      = item.address || {};
      const street = ((a.house_number ? a.house_number + ' ' : '') + (a.road || '')).trim();
      const city   = a.city || a.town || a.village || a.municipality || '';
      const province = PROVINCE_CODES[(a.state || '').toLowerCase()] || '';
      return { label: item.display_name, address: street, city, province, postal: a.postcode || '' };
    }).filter(s => s.address);

    res.json(suggestions);
  } catch (e) {
    console.error('Geocode error:', e.message);
    res.json([]); // dégradation silencieuse — la saisie manuelle reste possible
  }
});

// ═════════════════════════════════════════════════════════════════════════════
// CONTRATS
// ═════════════════════════════════════════════════════════════════════════════
function hydrateContract(c) {
  return {
    id: c.id, title: c.title, type: c.type,
    vendorId: c.vendorid, vendorName: c.vendorname || null,
    startDate: c.startdate, endDate: c.enddate, cost: c.cost ? parseFloat(c.cost) : null,
    coveredAssets: c.coveredassets, notes: c.notes, createdAt: c.createdat
  };
}
const CONTRACT_SELECT = `SELECT c.*, v.name AS vendorname FROM contracts c LEFT JOIN vendors v ON c.vendorid = v.id`;
app.get('/api/contracts', auth, async (req, res) => {
  try {
    const r = await pool.query(CONTRACT_SELECT + ' ORDER BY c.enddate ASC NULLS LAST');
    res.json(r.rows.map(hydrateContract));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.post('/api/contracts', auth, requirePermission('manage_contracts'), async (req, res) => {
  try {
    const { title, type, vendorId, startDate, endDate, cost, coveredAssets, notes } = req.body;
    if (!title) return res.status(400).json({ error: 'Le titre est obligatoire' });
    const id = uuidv4();
    await pool.query(
      'INSERT INTO contracts (id, title, type, vendorid, startdate, enddate, cost, coveredassets, notes, createdby, createdat) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,NOW())',
      [id, title, type || 'entretien', vendorId || null, startDate || null, endDate || null, cost || null, coveredAssets || null, notes || null, req.user.id]
    );
    const r = await pool.query(CONTRACT_SELECT + ' WHERE c.id=$1', [id]);
    res.json(hydrateContract(r.rows[0]));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.put('/api/contracts/:id', auth, requirePermission('manage_contracts'), async (req, res) => {
  try {
    const { title, type, vendorId, startDate, endDate, cost, coveredAssets, notes } = req.body;
    await pool.query(
      'UPDATE contracts SET title=$1, type=$2, vendorid=$3, startdate=$4, enddate=$5, cost=$6, coveredassets=$7, notes=$8 WHERE id=$9',
      [title, type || 'entretien', vendorId || null, startDate || null, endDate || null, cost || null, coveredAssets || null, notes || null, req.params.id]
    );
    const r = await pool.query(CONTRACT_SELECT + ' WHERE c.id=$1', [req.params.id]);
    if (!r.rows[0]) return res.status(404).json({ error: 'Contrat introuvable' });
    res.json(hydrateContract(r.rows[0]));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.delete('/api/contracts/:id', auth, requirePermission('manage_contracts'), async (req, res) => {
  try {
    await pool.query('DELETE FROM contracts WHERE id=$1', [req.params.id]);
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

app.get('/api/stats', auth, async (req, res) => {
  try {
    const totals = await pool.query(`
      SELECT COUNT(*) AS total,
        COALESCE(SUM(quantity), 0) AS totalquantity,
        COUNT(*) FILTER (WHERE warrantyuntil IS NOT NULL AND warrantyuntil < NOW() + INTERVAL '60 days' AND warrantyuntil >= NOW()) AS warrantysoon,
        COALESCE(SUM(purchaseprice * quantity), 0) AS inventoryvalue
      FROM assets
    `);
    const conSoon = await pool.query(`SELECT COUNT(*) AS c FROM contracts WHERE enddate IS NOT NULL AND enddate < NOW() + INTERVAL '60 days' AND enddate >= NOW()`);
    const row = totals.rows[0];
    res.json({
      total: parseInt(row.total, 10),
      totalQuantity: parseInt(row.totalquantity, 10),
      warrantySoon: parseInt(row.warrantysoon, 10),
      inventoryValue: parseFloat(row.inventoryvalue),
      contractsExpiringSoon: parseInt(conSoon.rows[0].c, 10)
    });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// NOTIFICATIONS INTERNES
// ═════════════════════════════════════════════════════════════════════════════
app.get('/api/notifications', auth, async (req, res) => {
  try {
    const r = await pool.query('SELECT * FROM notifications WHERE recipientid=$1 ORDER BY createdat DESC LIMIT 50', [req.user.id]);
    res.json(r.rows.map(n => ({ id: n.id, body: n.body, isRead: n.isread, createdAt: n.createdat })));
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.get('/api/notifications/unread-count', auth, async (req, res) => {
  try {
    const r = await pool.query('SELECT COUNT(*) AS c FROM notifications WHERE recipientid=$1 AND isread=false', [req.user.id]);
    res.json({ count: parseInt(r.rows[0].c, 10) });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});
app.put('/api/notifications/mark-read', auth, async (req, res) => {
  try {
    await pool.query('UPDATE notifications SET isread=true WHERE recipientid=$1 AND isread=false', [req.user.id]);
    res.json({ success: true });
  } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
});

// ═════════════════════════════════════════════════════════════════════════════
// ALERTES D'EXPIRATION — garanties, contrats
// ═════════════════════════════════════════════════════════════════════════════
const EXPIRY_ALERT_DAYS = 30;

async function notifyAdmins(bodyText) {
  const admins = await pool.query(`SELECT id FROM employees WHERE role IN ('admin','gestionnaire')`);
  for (const a of admins.rows) {
    await pool.query('INSERT INTO notifications (recipientid, body) VALUES ($1, $2)', [a.id, bodyText]).catch(() => {});
  }
}

async function checkExpirations() {
  try {
    const assets = await pool.query(
      `SELECT id, type, brand, model, serialnumber, warrantyuntil FROM assets
       WHERE warrantyuntil IS NOT NULL AND warrantyuntil < NOW() + INTERVAL '${EXPIRY_ALERT_DAYS} days' AND warrantynotified = false`
    );
    for (const a of assets.rows) {
      const label = [a.type, a.brand, a.model].filter(Boolean).join(' ') + (a.serialnumber ? ` (n° série ${a.serialnumber})` : '');
      const expired = new Date(a.warrantyuntil) < new Date();
      await notifyAdmins(`Garantie ${expired ? 'expirée' : 'expire bientôt'} : ${label} — ${expired ? 'expirée le' : 'jusqu\'au'} ${new Date(a.warrantyuntil).toLocaleDateString('fr-CA')}.`);
      await pool.query('UPDATE assets SET warrantynotified=true WHERE id=$1', [a.id]);
    }

    const contracts = await pool.query(
      `SELECT id, title, enddate FROM contracts
       WHERE enddate IS NOT NULL AND enddate < NOW() + INTERVAL '${EXPIRY_ALERT_DAYS} days' AND expirynotified = false`
    );
    for (const c of contracts.rows) {
      const expired = new Date(c.enddate) < new Date();
      await notifyAdmins(`Contrat ${expired ? 'expiré' : 'expire bientôt'} : ${c.title} — ${expired ? 'expiré le' : 'jusqu\'au'} ${new Date(c.enddate).toLocaleDateString('fr-CA')}.`);
      await pool.query('UPDATE contracts SET expirynotified=true WHERE id=$1', [c.id]);
    }

    if (assets.rows.length || contracts.rows.length) {
      console.log(`Alertes d'expiration envoyées : ${assets.rows.length} article(s), ${contracts.rows.length} contrat(s).`);
    }
  } catch (e) { console.error('Erreur vérification des expirations:', e.message); }
}

migrate().then(() => {
  app.listen(PORT, () => console.log(`🖥️  Vigie Inventory démarré sur le port ${PORT}`));
  checkExpirations();
  setInterval(checkExpirations, 24 * 60 * 60 * 1000); // vérification quotidienne
}).catch(e => { console.error('❌ Erreur de migration:', e); process.exit(1); });
