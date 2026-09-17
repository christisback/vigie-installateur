const { Pool } = require('pg');

if (!process.env.PGPASSWORD) {
  console.error('❌ FATAL: PGPASSWORD requis. Définissez la variable d\'environnement PGPASSWORD.');
  process.exit(1);
}

// Vigie Parc se connecte volontairement à LA MÊME base de données que
// Vigie Billets (tickets_db par défaut) — c'est ce qui lui permet de
// réutiliser directement les employés et les clients déjà existants,
// sans avoir à les ressaisir ni les synchroniser.
const DB_CONFIG = {
  user:     process.env.PGUSER     || 'postgres',
  host:     process.env.PGHOST     || 'localhost',
  database: process.env.PGDATABASE || 'tickets_db',
  password: process.env.PGPASSWORD,
  port:     process.env.PGPORT     || 5432,
};

const pool = new Pool({ ...DB_CONFIG, max: 20 });

module.exports = { pool, DB_CONFIG };
