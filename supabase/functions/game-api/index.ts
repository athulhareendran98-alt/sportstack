import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function respond(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json; charset=utf-8' },
  });
}

function cleanDisplayName(value: unknown): string {
  if (typeof value !== 'string') throw new Error('Enter a display name between 2 and 24 characters.');
  const name = value.trim().replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 24);
  if (name.length < 2 || name.length > 24) throw new Error('Enter a display name between 2 and 24 characters.');
  return name;
}

const ROOM_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function randomCode(length = 6): string {
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => ROOM_ALPHABET[byte % ROOM_ALPHABET.length]).join('');
}

function randomPlayerTag(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  const bytes = new Uint8Array(4);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => alphabet[byte % alphabet.length]).join('');
}

function errorMessage(error: { message?: string; code?: string } | null, fallback: string): string {
  const message = error?.message || fallback;
  if (message.includes('ROOM_NOT_FOUND')) return 'ROOM_NOT_FOUND';
  if (message.includes('ROOM_FULL')) return 'ROOM_FULL';
  if (message.includes('ROOM_NOT_JOINABLE')) return 'ROOM_NOT_JOINABLE';
  if (message.includes('NOT_A_ROOM_MEMBER')) return 'NOT_A_ROOM_MEMBER';
  if (message.includes('INVALID_DISPLAY_NAME')) return 'INVALID_DISPLAY_NAME';
  if (message.includes('ROOM_NOT_WAITING')) return 'ROOM_NOT_WAITING';
  if (message.includes('NOT_HOST')) return 'NOT_HOST';
  if (message.includes('NOT_ENOUGH_READY')) return 'NOT_ENOUGH_READY';
  if (message.includes('TOO_MANY_VOTES')) return 'TOO_MANY_VOTES';
  if (message.includes('INVALID_CATEGORY')) return 'INVALID_CATEGORY';
  if (message.includes('NOT_ENOUGH_QUESTIONS')) return 'NOT_ENOUGH_QUESTIONS';
  if (message.includes('ATTEMPT_NOT_FOUND')) return 'ATTEMPT_NOT_FOUND';
  if (message.includes('TOO_LATE')) return 'TOO_LATE';
  if (message.includes('ALREADY_ANSWERED')) return 'ALREADY_ANSWERED';
  if (message.includes('INVALID_ANSWER')) return 'INVALID_ANSWER';
  if (message.includes('NOT_REVEALED')) return 'NOT_REVEALED';
  if (message.includes('MATCH_NOT_FOUND')) return 'MATCH_NOT_FOUND';
  return message;
}

Deno.serve(async (request: Request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return respond({ error: 'Method not allowed.' }, 405);

  const projectUrl = Deno.env.get('SUPABASE_URL');
  const publicKey = Deno.env.get('SUPABASE_PUBLISHABLE_KEY') || Deno.env.get('SUPABASE_ANON_KEY');
  const secretKey = Deno.env.get('SUPABASE_SECRET_KEY') || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!projectUrl || !publicKey || !secretKey) {
    console.error('Missing Supabase URL, public key, or server secret key.');
    return respond({ error: 'Server setup is incomplete. Check the game-api function secrets.' }, 500);
  }

  const authorization = request.headers.get('Authorization');
  if (!authorization?.startsWith('Bearer ')) return respond({ error: 'Please connect as a guest first.' }, 401);
  const accessToken = authorization.slice('Bearer '.length);

  const authClient = createClient(projectUrl, publicKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authorization } },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser(accessToken);
  if (authError || !authData.user) return respond({ error: 'Your guest session has expired. Return home and reconnect.' }, 401);
  const userId = authData.user.id;

  const admin = createClient(projectUrl, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let body: Record<string, unknown>;
  try {
    body = await request.json();
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('Invalid request body.');
  } catch {
    return respond({ error: 'Invalid JSON request.' }, 400);
  }

  const action = body.action;
  try {
    if (action === 'create_room') {
      const displayName = cleanDisplayName(body.displayName);
      let lastError: { message?: string; code?: string } | null = null;
      for (let attempt = 0; attempt < 5; attempt += 1) {
        const code = randomCode();
        const { data, error } = await admin.rpc('create_room_v1', {
          p_user_id: userId,
          p_display_name: displayName,
          p_player_tag: randomPlayerTag(),
          p_room_code: code,
        });
        if (!error && data) return respond(data);
        lastError = error;
        if (error?.code !== '23505') break;
      }
      return respond({ error: errorMessage(lastError, 'Could not create a room. Please try again.') }, 400);
    }

    if (action === 'list_rooms') {
      const { error: cleanupError } = await admin.rpc('cleanup_stale_waiting_rooms_v1');
      if (cleanupError) console.warn('Room cleanup skipped:', cleanupError.message);
      const { data: rows, error } = await admin
        .from('rooms')
        .select('id, code, status, host_id, max_players, created_at')
        .eq('status', 'waiting')
        .order('created_at', { ascending: false })
        .limit(50);
      if (error) throw error;
      if (!rows?.length) return respond({ rooms: [] });

      const ids = rows.map((row) => row.id);
      const { data: playerRows, error: playerError } = await admin
        .from('room_players')
        .select('room_id, display_name, player_tag, is_ready, joined_at')
        .in('room_id', ids)
        .eq('status', 'active')
        .order('joined_at', { ascending: true });
      if (playerError) throw playerError;

      const grouped = new Map<string, typeof playerRows>();
      for (const player of playerRows || []) {
        const existing = grouped.get(player.room_id) || [];
        existing.push(player);
        grouped.set(player.room_id, existing);
      }
      const rooms = rows.map((row) => {
        const players = grouped.get(row.id) || [];
        return {
          ...row,
          players: players.map(({ display_name, player_tag, is_ready }) => ({ display_name, player_tag, is_ready })),
          player_count: players.length,
        };
      }).filter((row) => row.player_count >= 1 && row.player_count < row.max_players);
      return respond({ rooms });
    }

    if (action === 'join_room') {
      const code = typeof body.code === 'string' ? body.code.trim().toUpperCase() : '';
      if (!/^[A-Z0-9]{6}$/.test(code)) return respond({ error: 'Enter a valid six-character room code.' }, 400);
      const displayName = cleanDisplayName(body.displayName);
      const { data, error } = await admin.rpc('join_room_v1', {
        p_room_code: code,
        p_user_id: userId,
        p_display_name: displayName,
        p_player_tag: randomPlayerTag(),
      });
      if (error) return respond({ error: errorMessage(error, 'Could not join that room.') }, 400);
      return respond(data);
    }

    if (action === 'room_snapshot') {
      const roomId = typeof body.roomId === 'string' ? body.roomId : '';
      if (!/^[0-9a-f-]{36}$/i.test(roomId)) return respond({ error: 'Invalid room identifier.' }, 400);
      const { data, error } = await admin.rpc('get_room_snapshot_v1', {
        p_room_id: roomId,
        p_user_id: userId,
      });
      if (error) return respond({ error: errorMessage(error, 'Could not load the room.') }, 400);
      return respond(data);
    }

    if (action === 'set_ready') {
      const roomId = typeof body.roomId === 'string' ? body.roomId : '';
      if (!/^[0-9a-f-]{36}$/i.test(roomId)) return respond({ error: 'Invalid room identifier.' }, 400);
      const isReady = body.isReady === true;
      const { data, error } = await admin.rpc('set_room_ready_v1', {
        p_room_id: roomId,
        p_user_id: userId,
        p_ready: isReady,
      });
      if (error) return respond({ error: errorMessage(error, 'Could not update readiness.') }, 400);
      return respond(data);
    }

    if (action === 'set_category_votes') {
      const roomId = typeof body.roomId === 'string' ? body.roomId : '';
      if (!/^[0-9a-f-]{36}$/i.test(roomId)) return respond({ error: 'Invalid room identifier.' }, 400);
      const categories = Array.isArray(body.categories) ? body.categories : null;
      if (!categories || categories.length > 2 || !categories.every((item) => typeof item === 'string' && /^[a-z0-9-]{1,64}$/.test(item))) {
        return respond({ error: 'TOO_MANY_VOTES' }, 400);
      }
      const { data, error } = await admin.rpc('set_category_votes_v1', {
        p_room_id: roomId,
        p_user_id: userId,
        p_categories: categories,
      });
      if (error) return respond({ error: errorMessage(error, 'Could not save your category votes.') }, 400);
      return respond(data);
    }

    if (action === 'start_countdown') {
      const roomId = typeof body.roomId === 'string' ? body.roomId : '';
      if (!/^[0-9a-f-]{36}$/i.test(roomId)) return respond({ error: 'Invalid room identifier.' }, 400);
      const { data, error } = await admin.rpc('start_countdown_v1', {
        p_room_id: roomId,
        p_user_id: userId,
      });
      if (error) return respond({ error: errorMessage(error, 'Could not start the countdown.') }, 400);
      return respond(data);
    }

    if (action === 'advance_countdown') {
      const roomId = typeof body.roomId === 'string' ? body.roomId : '';
      if (!/^[0-9a-f-]{36}$/i.test(roomId)) return respond({ error: 'Invalid room identifier.' }, 400);
      const { data, error } = await admin.rpc('advance_countdown_v1', {
        p_room_id: roomId,
        p_user_id: userId,
      });
      if (error) return respond({ error: errorMessage(error, 'Could not update the countdown.') }, 400);
      return respond(data);
    }

    if (action === 'solo_categories') {
      const { data, error } = await admin.rpc('list_solo_categories_v1');
      if (error) return respond({ error: errorMessage(error, 'Could not load the categories.') }, 400);
      return respond({ categories: data });
    }

    if (action === 'solo_active') {
      const { data, error } = await admin.rpc('get_active_solo_attempt_v1', { p_user_id: userId });
      if (error) return respond({ error: errorMessage(error, 'Could not check for an unfinished challenge.') }, 400);
      return respond(data);
    }

    if (action === 'solo_start') {
      const category = typeof body.category === 'string' ? body.category : '';
      if (!/^[a-z0-9-]{1,64}$/.test(category)) return respond({ error: 'INVALID_CATEGORY' }, 400);
      const { data, error } = await admin.rpc('start_solo_challenge_v1', { p_user_id: userId, p_category: category });
      if (error) return respond({ error: errorMessage(error, 'Could not start the challenge.') }, 400);
      return respond(data);
    }

    if (action === 'solo_state' || action === 'solo_next') {
      const attemptId = typeof body.attemptId === 'string' ? body.attemptId : '';
      if (!/^[0-9a-f-]{36}$/i.test(attemptId)) return respond({ error: 'ATTEMPT_NOT_FOUND' }, 400);
      const rpcName = action === 'solo_state' ? 'get_solo_state_v1' : 'advance_solo_v1';
      const { data, error } = await admin.rpc(rpcName, { p_attempt_id: attemptId, p_user_id: userId });
      if (error) return respond({ error: errorMessage(error, 'Could not load the challenge.') }, 400);
      return respond(data);
    }

    if (action === 'solo_answer') {
      const attemptId = typeof body.attemptId === 'string' ? body.attemptId : '';
      const answer = typeof body.answer === 'string' ? body.answer : '';
      if (!/^[0-9a-f-]{36}$/i.test(attemptId)) return respond({ error: 'ATTEMPT_NOT_FOUND' }, 400);
      if (answer.length < 1 || answer.length > 200) return respond({ error: 'INVALID_ANSWER' }, 400);
      const { data, error } = await admin.rpc('submit_solo_answer_v1', {
        p_attempt_id: attemptId,
        p_user_id: userId,
        p_answer: answer,
      });
      if (error) return respond({ error: errorMessage(error, 'Could not lock in your answer.') }, 400);
      return respond(data);
    }

    if (action === 'match_state') {
      const roomId = typeof body.roomId === 'string' ? body.roomId : '';
      if (!/^[0-9a-f-]{36}$/i.test(roomId)) return respond({ error: 'Invalid room identifier.' }, 400);
      const { data, error } = await admin.rpc('get_match_state_v1', { p_room_id: roomId, p_user_id: userId });
      if (error) return respond({ error: errorMessage(error, 'Could not load the match.') }, 400);
      return respond(data);
    }

    if (action === 'match_answer') {
      const roomId = typeof body.roomId === 'string' ? body.roomId : '';
      const answer = typeof body.answer === 'string' ? body.answer : '';
      if (!/^[0-9a-f-]{36}$/i.test(roomId)) return respond({ error: 'Invalid room identifier.' }, 400);
      if (answer.length < 1 || answer.length > 200) return respond({ error: 'INVALID_ANSWER' }, 400);
      const { data, error } = await admin.rpc('submit_match_answer_v1', {
        p_room_id: roomId,
        p_user_id: userId,
        p_answer: answer,
      });
      if (error) return respond({ error: errorMessage(error, 'Could not lock in your answer.') }, 400);
      return respond(data);
    }

    if (action === 'leave_room') {
      const roomId = typeof body.roomId === 'string' ? body.roomId : '';
      if (!/^[0-9a-f-]{36}$/i.test(roomId)) return respond({ error: 'Invalid room identifier.' }, 400);
      const { data, error } = await admin.rpc('leave_room_v1', {
        p_room_id: roomId,
        p_user_id: userId,
      });
      if (error) return respond({ error: errorMessage(error, 'Could not leave the room.') }, 400);
      return respond(data);
    }

    if (action === 'heartbeat') {
      const roomId = typeof body.roomId === 'string' ? body.roomId : '';
      if (!/^[0-9a-f-]{36}$/i.test(roomId)) return respond({ error: 'Invalid room identifier.' }, 400);
      const { data, error } = await admin.rpc('touch_room_presence_v1', {
        p_room_id: roomId,
        p_user_id: userId,
      });
      if (error) return respond({ error: errorMessage(error, 'Could not update room presence.') }, 400);
      return respond(data);
    }

    return respond({ error: 'Unknown action.' }, 400);
  } catch (error) {
    console.error('game-api error:', error);
    return respond({ error: error instanceof Error ? error.message : 'Unexpected server error.' }, 500);
  }
});
