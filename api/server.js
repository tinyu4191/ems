// server.js
import Fastify from 'fastify';
import pg from 'pg';
import { registerReportsRoute } from './routes/reports.js';

const { Pool } = pg;

const fastify = Fastify({ logger: true });

const pool = new Pool({
  host: process.env.DB_HOST || 'timescaledb',
  port: process.env.DB_PORT || 5432,
  user: process.env.DB_USER,
  password: process.env.DB_PASS,
  database: process.env.DB_NAME,
  max: 10,
});

fastify.decorate('pg', pool);

registerReportsRoute(fastify);

fastify.get('/api/health', async () => ({ status: 'ok' }));

const start = async () => {
  try {
    await fastify.listen({ host: '0.0.0.0', port: 4000 });
  } catch (err) {
    fastify.log.error(err);
    process.exit(1);
  }
};

start();
