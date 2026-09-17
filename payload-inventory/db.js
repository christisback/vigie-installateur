const { Pool } = require('pg');

if (!process.env.PGPASSWORD) {
  console.error('❌ FATAL: PGPASSWORD requis. Définissez la variable d\'environnement PGPASSWORD.');
  process.exit(1);
}

// Vigie Inventory est un produit autonome — sa propre base de données,
// indépendante de Vigie Billets/Vigie Parc, pour qu'il fonctionne seul
// chez n'importe quelle entreprise.
const DB_CONFIG = {
  user:     process.env.PGUSER     || 'postgres',
  host:     process.env.PGHOST     || 'localhost',
  database: process.env.PGDATABASE || 'vigie_inventory_db',
  password: process.env.PGPASSWORD,
  port:     process.env.PGPORT     || 5432,
};

const pool = new Pool({ ...DB_CONFIG, max: 20 });

module.exports = { pool, DB_CONFIG };
