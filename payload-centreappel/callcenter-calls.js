'use strict';
/**
 * Vigie Centre d'Appel : appels internes entre employés (WebRTC de poste à poste), même principe que
 * calls.js dans Vigie Billets, adapté pour cette application séparée.
 *
 * Le serveur ne fait que la sonnerie et la mise en relation (signalisation). La voix ne passe JAMAIS par lui :
 * elle circule directement entre les deux navigateurs, chiffrée. Aucun enregistrement.
 *
 * Canal temps réel : un flux SSE par navigateur (GET /api/callcenter/stream). L'état des appels est gardé en
 * mémoire ; la base ne conserve que l'historique (table callcenter_calls).
 */

const RING_SECONDS = Number(process.env.CALL_RING_SECONDS) || 45;
const ACTIVE_GRACE_MS = Number(process.env.CALL_ACTIVE_GRACE_MS) || 60 * 1000;
const RING_GRACE_MS = Number(process.env.CALL_RING_GRACE_MS) || 10 * 1000;
const STREAM_MAX_MS = 30 * 60 * 1000;
const MAX_SIGNAL_BYTES = 20000;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Migration additive : aucune donnée de Billets n'est touchée, ces tables/permissions sont propres à cette app
const CALLCENTER_MIGRATION_SQL = `
  CREATE TABLE IF NOT EXISTS callcenter_calls (
    id UUID PRIMARY KEY,
    callerid UUID REFERENCES employees(id) ON DELETE SET NULL,
    calleeid UUID REFERENCES employees(id) ON DELETE SET NULL,
    linkticketid UUID REFERENCES tickets(id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'ringing',
    createdat TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    answeredat TIMESTAMPTZ,
    endedat TIMESTAMPTZ,
    endreason TEXT,
    istransfer BOOLEAN NOT NULL DEFAULT false,
    parentcallid UUID REFERENCES callcenter_calls(id) ON DELETE SET NULL,
    transferby UUID REFERENCES employees(id) ON DELETE SET NULL
  );
  CREATE INDEX IF NOT EXISTS idx_callcenter_calls_caller ON callcenter_calls(callerid, createdat DESC);
  CREATE INDEX IF NOT EXISTS idx_callcenter_calls_callee ON callcenter_calls(calleeid, createdat DESC);
  INSERT INTO role_permissions (role, permission, allowed) VALUES
    ('gestionnaire','use_callcenter',true), ('employee','use_callcenter',true)
  ON CONFLICT (role,permission) DO NOTHING;
`;

function iceServersFromEnv() {
  try {
    const raw = process.env.CALLCENTER_ICE_SERVERS;
    if (!raw) return [];
    const list = JSON.parse(raw);
    return Array.isArray(list) ? list.slice(0, 5) : [];
  } catch { return []; }
}

function initCallcenterCalls({ app, pool, auth, hasPermission, uuidv4 }) {
  const streams = new Map();  // userId -> Set(res)
  const calls = new Map();    // callId -> appel en mémoire
  const byUser = new Map();   // userId -> callId (appel qui sonne ou en cours)

  async function migrate() {
    for (let attempt = 1; attempt <= 6; attempt++) {
      try {
        await pool.query(CALLCENTER_MIGRATION_SQL);
        await pool.query(
          `UPDATE callcenter_calls SET status='ended', endedat=NOW(), endreason='redémarrage du serveur' WHERE status IN ('ringing','active','hold')`
        );
        return;
      } catch (e) {
        if (attempt === 6) { console.warn('Migration centre d\'appel:', e.message); return; }
        await new Promise(r => setTimeout(r, 2000 * attempt));
      }
    }
  }
  const ready = migrate();

  async function allowed(user) {
    return hasPermission(user.role, 'use_callcenter');
  }

  function push(userId, event, data) {
    const set = streams.get(userId);
    if (!set) return;
    const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const r of set) { try { r.write(msg); } catch { /* connexion fermée */ } }
  }
  const reachable = userId => (streams.get(userId)?.size || 0) > 0;

  function publicCall(c) {
    return { callId: c.id, callerId: c.callerId, callerName: c.callerName, calleeId: c.calleeId, calleeName: c.calleeName, ticketId: c.ticketId };
  }

  async function finish(call, status, reason) {
    if (call.finished) return;
    call.finished = true;
    clearTimeout(call.ringTimer);
    for (const t of Object.values(call.graceTimers)) clearTimeout(t);
    calls.delete(call.id);
    if (byUser.get(call.callerId) === call.id) byUser.delete(call.callerId);
    if (byUser.get(call.calleeId) === call.id) byUser.delete(call.calleeId);

    const seconds = call.answeredAt ? Math.round((Date.now() - call.answeredAt) / 1000) : 0;
    const msgStatus = status === 'cancelled' ? 'missed' : status;
    try {
      await pool.query(
        `UPDATE callcenter_calls SET status=$2, endedat=NOW(), endreason=$3 WHERE id=$1`, [call.id, status, reason || null]
      );
    } catch (e) { console.error('Appel, enregistrement de fin:', e.message); }

    const evt = { callId: call.id, status: msgStatus, seconds, reason: reason || null };
    push(call.callerId, 'ended', evt);
    push(call.calleeId, 'ended', evt);

    if (call.isTransfer && call.parentCallId) {
      const parent = calls.get(call.parentCallId);
      if (parent && parent.pendingTransfer === call.id) resumeCall(parent, 'transfer_failed');
    }
  }

  function resumeCall(call, reasonKey) {
    call.status = 'active'; call.holdBy = null; call.holdReason = null; call.pendingTransfer = null;
    pool.query(`UPDATE callcenter_calls SET status='active' WHERE id=$1`, [call.id]).catch(() => {});
    const payload = { callId: call.id, reason: reasonKey || null };
    push(call.callerId, 'resume', payload);
    push(call.calleeId, 'resume', payload);
  }

  async function endCallCascade(call, status, reason) {
    const pendingId = call.pendingTransfer;
    await finish(call, status, reason);
    if (pendingId) {
      const t = calls.get(pendingId);
      if (t && !t.finished) await finish(t, t.status === 'ringing' ? 'cancelled' : 'ended', 'appel raccroché pendant le transfert');
    }
  }

  async function finalizeTransfer(tcall) {
    const parent = calls.get(tcall.parentCallId);
    if (!parent) return;
    const otherPartyId = tcall.callerId;
    const requesterId  = parent.callerId === otherPartyId ? parent.calleeId   : parent.callerId;

    parent.finished = true;
    clearTimeout(parent.ringTimer);
    for (const t of Object.values(parent.graceTimers)) clearTimeout(t);
    calls.delete(parent.id);
    if (byUser.get(parent.callerId) === parent.id) byUser.delete(parent.callerId);
    if (byUser.get(parent.calleeId) === parent.id) byUser.delete(parent.calleeId);
    byUser.set(otherPartyId, tcall.id);

    const seconds = parent.answeredAt ? Math.round((Date.now() - parent.answeredAt) / 1000) : 0;
    try {
      await pool.query(`UPDATE callcenter_calls SET status='transferred', endedat=NOW(), endreason=$2 WHERE id=$1`, [parent.id, 'transféré à ' + tcall.calleeName]);
    } catch (e) { console.error('Transfert, enregistrement:', e.message); }

    push(requesterId, 'ended', { callId: parent.id, status: 'transferred', seconds, transferToName: tcall.calleeName });
    push(otherPartyId, 'transfer-connect', { callId: tcall.id, peerId: tcall.calleeId, peerName: tcall.calleeName });
  }

  function ownCall(req, res) {
    const id = req.params.id;
    const call = UUID_RE.test(id) ? calls.get(id) : null;
    if (!call || (call.callerId !== req.user.id && call.calleeId !== req.user.id)) {
      res.status(404).json({ error: 'Appel introuvable ou déjà terminé', code: 'gone' });
      return null;
    }
    return call;
  }

  app.get('/api/callcenter/config', auth, async (req, res) => {
    try {
      res.json({ canCall: await hasPermission(req.user.role, 'use_callcenter'), iceServers: iceServersFromEnv() });
    } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
  });

  app.get('/api/callcenter/stream', auth, async (req, res) => {
    try {
      if (!(await allowed(req.user))) return res.status(403).json({ error: "Le centre d'appel n'est pas disponible pour ce compte" });
      req.socket.setTimeout(0);
      res.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-store, no-transform', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' });
      res.write('retry: 3000\n\n');

      const uid = req.user.id;
      if (!streams.has(uid)) streams.set(uid, new Set());
      streams.get(uid).add(res);
      const cur = calls.get(byUser.get(uid));
      if (cur && cur.graceTimers[uid]) { clearTimeout(cur.graceTimers[uid]); delete cur.graceTimers[uid]; }
      res.write(`event: hello\ndata: ${JSON.stringify({ ok: true, iceServers: iceServersFromEnv(), inCall: cur ? cur.id : null })}\n\n`);

      const keepAlive = setInterval(() => { try { res.write(': ping\n\n'); } catch { /* fermé */ } }, 20000);
      const maxAge = setTimeout(() => { try { res.end(); } catch { /* fermé */ } }, STREAM_MAX_MS);
      req.on('close', () => {
        clearInterval(keepAlive); clearTimeout(maxAge);
        const set = streams.get(uid);
        if (set) { set.delete(res); if (!set.size) streams.delete(uid); }
        const c = calls.get(byUser.get(uid));
        if (c && !reachable(uid) && !c.graceTimers[uid]) {
          const busy = c.status === 'active' || c.status === 'hold';
          const ms = busy ? ACTIVE_GRACE_MS : RING_GRACE_MS;
          c.graceTimers[uid] = setTimeout(() => {
            if (!reachable(uid)) endCallCascade(c, busy ? 'ended' : 'missed', 'connexion perdue');
          }, ms);
        }
      });
    } catch (e) { console.error(e); if (!res.headersSent) res.status(500).json({ error: 'Erreur serveur' }); }
  });

  app.post('/api/callcenter/calls', auth, async (req, res) => {
    try {
      await ready;
      if (!(await allowed(req.user))) return res.status(403).json({ error: "Le centre d'appel n'est pas disponible pour ce compte", code: 'forbidden' });
      const { calleeId, ticketId } = req.body || {};
      if (!UUID_RE.test(String(calleeId || ''))) return res.status(400).json({ error: 'Destinataire requis' });
      if (calleeId === req.user.id) return res.status(400).json({ error: 'Impossible de vous appeler vous-même' });
      if (byUser.has(req.user.id)) return res.status(409).json({ error: 'Vous êtes déjà en appel', code: 'busy_self' });

      const callee = (await pool.query('SELECT id, name, role FROM employees WHERE id=$1', [calleeId])).rows[0];
      if (!callee) return res.status(404).json({ error: 'Employé introuvable' });
      if (!(await hasPermission(callee.role, 'use_callcenter'))) return res.status(403).json({ error: "Cette personne n'a pas accès au centre d'appel", code: 'callee_forbidden' });
      if (byUser.has(callee.id)) return res.status(409).json({ error: 'Cette personne est déjà en appel', code: 'busy' });
      if (!reachable(callee.id)) return res.status(409).json({ error: "Cette personne n'est pas joignable en ce moment.", code: 'unreachable' });

      let ticket = null;
      if (ticketId) {
        if (!UUID_RE.test(String(ticketId))) return res.status(400).json({ error: 'Billet invalide' });
        ticket = (await pool.query('SELECT id FROM tickets WHERE id=$1', [ticketId])).rows[0] || null;
      }

      const caller = (await pool.query('SELECT name FROM employees WHERE id=$1', [req.user.id])).rows[0];
      const call = {
        id: uuidv4(), callerId: req.user.id, callerName: caller?.name || 'Collègue', calleeId: callee.id, calleeName: callee.name,
        ticketId: ticket ? ticket.id : null,
        status: 'ringing', answeredAt: null, finished: false, graceTimers: {}, ringTimer: null,
      };
      await pool.query('INSERT INTO callcenter_calls (id, callerid, calleeid, linkticketid, status) VALUES ($1,$2,$3,$4,$5)', [call.id, call.callerId, call.calleeId, call.ticketId, 'ringing']);
      calls.set(call.id, call);
      byUser.set(call.callerId, call.id);
      byUser.set(call.calleeId, call.id);
      call.ringTimer = setTimeout(() => finish(call, 'missed', 'sans réponse'), RING_SECONDS * 1000);

      push(call.calleeId, 'incoming', publicCall(call));
      res.json({ callId: call.id, peerName: callee.name, iceServers: iceServersFromEnv(), ringSeconds: RING_SECONDS });
    } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
  });

  app.post('/api/callcenter/calls/:id/accept', auth, async (req, res) => {
    const call = ownCall(req, res); if (!call) return;
    if (call.calleeId !== req.user.id) return res.status(403).json({ error: 'Seul le destinataire peut répondre' });
    if (call.status !== 'ringing') return res.status(409).json({ error: 'Cet appel ne sonne plus', code: 'gone' });
    clearTimeout(call.ringTimer);
    call.status = 'active'; call.answeredAt = Date.now();
    pool.query(`UPDATE callcenter_calls SET status='active', answeredat=NOW() WHERE id=$1`, [call.id]).catch(() => {});
    push(call.callerId, 'accepted', { callId: call.id });
    push(call.calleeId, 'answered', { callId: call.id });
    if (call.isTransfer) await finalizeTransfer(call);
    res.json({ callId: call.id, peerName: call.callerName, iceServers: iceServersFromEnv() });
  });

  app.post('/api/callcenter/calls/:id/decline', auth, async (req, res) => {
    const call = ownCall(req, res); if (!call) return;
    if (call.calleeId !== req.user.id || call.status !== 'ringing') return res.status(409).json({ error: 'Cet appel ne sonne plus', code: 'gone' });
    await finish(call, 'declined', 'refusé');
    res.json({ success: true });
  });

  app.post('/api/callcenter/calls/:id/cancel', auth, async (req, res) => {
    const call = ownCall(req, res); if (!call) return;
    if (call.callerId !== req.user.id || call.status !== 'ringing') return res.status(409).json({ error: 'Cet appel ne sonne plus', code: 'gone' });
    await finish(call, 'cancelled', 'annulé par l\'appelant');
    res.json({ success: true });
  });

  app.post('/api/callcenter/calls/:id/end', auth, async (req, res) => {
    const call = ownCall(req, res); if (!call) return;
    if (call.status === 'ringing') {
      await endCallCascade(call, call.callerId === req.user.id ? 'cancelled' : 'declined', 'raccroché');
    } else {
      await endCallCascade(call, 'ended', 'raccroché');
    }
    res.json({ success: true });
  });

  app.post('/api/callcenter/calls/:id/hold', auth, async (req, res) => {
    const call = ownCall(req, res); if (!call) return;
    if (call.status !== 'active') return res.status(409).json({ error: 'Cet appel ne peut pas être mis en attente maintenant', code: 'not_active' });
    const byId = req.user.id;
    const byName = call.callerId === byId ? call.callerName : call.calleeName;
    call.status = 'hold'; call.holdBy = byId; call.holdReason = 'manual'; call.pendingTransfer = null;
    pool.query(`UPDATE callcenter_calls SET status='hold' WHERE id=$1`, [call.id]).catch(() => {});
    const payload = { callId: call.id, byUserId: byId, byName, reason: 'manual' };
    push(call.callerId, 'hold', payload);
    push(call.calleeId, 'hold', payload);
    res.json({ success: true });
  });

  app.post('/api/callcenter/calls/:id/resume', auth, async (req, res) => {
    const call = ownCall(req, res); if (!call) return;
    if (call.status !== 'hold') return res.status(409).json({ error: "Cet appel n'est pas en attente", code: 'not_hold' });
    if (call.pendingTransfer) return res.status(409).json({ error: 'Un transfert est en cours pour cet appel', code: 'transfer_pending' });
    if (call.holdBy !== req.user.id) return res.status(403).json({ error: "Seule la personne qui a mis l'appel en attente peut le reprendre" });
    resumeCall(call, null);
    res.json({ success: true });
  });

  app.post('/api/callcenter/calls/:id/transfer', auth, async (req, res) => {
    try {
      await ready;
      const call = ownCall(req, res); if (!call) return;
      if (call.status !== 'active') return res.status(409).json({ error: 'Cet appel ne peut pas être transféré maintenant', code: 'not_active' });
      const requesterId = req.user.id;
      const otherPartyId = call.callerId === requesterId ? call.calleeId : call.callerId;
      const otherPartyName = call.callerId === requesterId ? call.calleeName : call.callerName;
      const requesterName = call.callerId === requesterId ? call.callerName : call.calleeName;

      const { toEmployeeId } = req.body || {};
      if (!UUID_RE.test(String(toEmployeeId || ''))) return res.status(400).json({ error: 'Choisissez la personne à qui transférer l\'appel' });
      if (toEmployeeId === requesterId) return res.status(400).json({ error: 'Vous ne pouvez pas vous transférer l\'appel à vous-même' });
      if (toEmployeeId === otherPartyId) return res.status(400).json({ error: 'Cette personne participe déjà à l\'appel' });

      const target = (await pool.query('SELECT id, name, role FROM employees WHERE id=$1', [toEmployeeId])).rows[0];
      if (!target) return res.status(404).json({ error: 'Employé introuvable' });
      if (!(await hasPermission(target.role, 'use_callcenter'))) return res.status(403).json({ error: "Cette personne n'a pas accès au centre d'appel", code: 'callee_forbidden' });
      if (byUser.has(target.id)) return res.status(409).json({ error: 'Cette personne est déjà en appel', code: 'busy' });
      if (!reachable(target.id)) return res.status(409).json({ error: "Cette personne n'est pas joignable en ce moment.", code: 'unreachable' });

      const tcall = {
        id: uuidv4(), callerId: otherPartyId, callerName: otherPartyName, calleeId: target.id, calleeName: target.name,
        ticketId: call.ticketId || null,
        status: 'ringing', answeredAt: null, finished: false, graceTimers: {}, ringTimer: null,
        isTransfer: true, parentCallId: call.id, transferByName: requesterName,
      };
      await pool.query(
        `INSERT INTO callcenter_calls (id, callerid, calleeid, linkticketid, status, istransfer, parentcallid, transferby)
         VALUES ($1,$2,$3,$4,'ringing',true,$5,$6)`,
        [tcall.id, tcall.callerId, tcall.calleeId, tcall.ticketId, call.id, requesterId]
      );
      calls.set(tcall.id, tcall);
      byUser.set(target.id, tcall.id);
      tcall.ringTimer = setTimeout(() => finish(tcall, 'missed', 'sans réponse'), RING_SECONDS * 1000);

      call.status = 'hold'; call.holdBy = requesterId; call.holdReason = 'transfer'; call.pendingTransfer = tcall.id;
      pool.query(`UPDATE callcenter_calls SET status='hold' WHERE id=$1`, [call.id]).catch(() => {});

      const holdPayload = { callId: call.id, byUserId: requesterId, byName: requesterName, reason: 'transfer', transferToName: target.name };
      push(requesterId, 'hold', holdPayload);
      push(otherPartyId, 'hold', holdPayload);
      push(target.id, 'incoming', { ...publicCall(tcall), isTransfer: true, transferByName: requesterName });

      res.json({ transferCallId: tcall.id, toName: target.name });
    } catch (e) { console.error(e); res.status(500).json({ error: 'Erreur serveur' }); }
  });

  app.post('/api/callcenter/calls/:id/signal', auth, async (req, res) => {
    const call = ownCall(req, res); if (!call) return;
    if (call.status !== 'active') return res.status(409).json({ error: "L'appel n'est pas en cours", code: 'gone' });
    const { type, data } = req.body || {};
    if (!['offer', 'answer', 'ice'].includes(type)) return res.status(400).json({ error: 'Type de signal invalide' });
    const size = JSON.stringify(data === undefined ? null : data).length;
    if (size > MAX_SIGNAL_BYTES) return res.status(413).json({ error: 'Signal trop gros' });
    const to = call.callerId === req.user.id ? call.calleeId : call.callerId;
    push(to, 'signal', { callId: call.id, type, data });
    res.json({ success: true });
  });

  return { ready, _state: { streams, calls, byUser } };
}

module.exports = { initCallcenterCalls, CALLCENTER_MIGRATION_SQL };
