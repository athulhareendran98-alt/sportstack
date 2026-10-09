import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { FormEvent } from 'react';
import type { PublicRoom, RoomSnapshot, SavedRoom } from './types';
import { gameApi, GameApiError } from './lib/gameApi';
import { isSupabaseConfigured, supabase } from './lib/supabase';
import { launchCategories } from './data/categories';
import SoloChallenge from './SoloChallenge';
import MultiplayerMatch from './MultiplayerMatch';

type Screen = 'home' | 'lobby' | 'room' | 'solo';
type Notice = { text: string; tone: 'info' | 'error' | 'success' } | null;

const ACTIVE_ROOM_KEY = 'sportstack_active_room';
const DISPLAY_NAME_KEY = 'sportstack_display_name';
const TAB_SESSION_KEY = 'sportstack_tab_session';

function readSavedRoom(): SavedRoom | null {
  try {
    const raw = localStorage.getItem(ACTIVE_ROOM_KEY);
    if (!raw) return null;
    const saved = JSON.parse(raw) as SavedRoom;
    return saved?.id && saved?.code ? saved : null;
  } catch {
    return null;
  }
}

function friendlyError(error: unknown): string {
  if (error instanceof GameApiError) {
    const text = error.message || 'Something went wrong. Please try again.';
    if (text.includes('ROOM_FULL')) return 'That room is full. Choose another room.';
    if (text.includes('ROOM_NOT_FOUND')) return 'That room no longer exists. Refresh the room list.';
    if (text.includes('ROOM_NOT_JOINABLE')) return 'That room has already started or closed.';
    if (text.includes('NOT_A_ROOM_MEMBER')) return 'You are no longer in that room.';
    if (text.includes('NOT_ENOUGH_READY')) return 'At least two players must be ready before the match can start.';
    if (text.includes('NOT_HOST')) return 'Only the room host can start the match.';
    if (text.includes('ROOM_NOT_WAITING')) return 'The match has already started, so this can no longer be changed.';
    if (text.includes('TOO_MANY_VOTES')) return 'You can vote for up to two categories.';
    if (text.includes('INVALID_CATEGORY')) return 'That category is not available.';
    if (text.includes('NOT_ENOUGH_QUESTIONS')) return 'That category does not have enough questions yet.';
    if (text.includes('ATTEMPT_NOT_FOUND')) return 'That challenge could not be found. Start a new one.';
    if (text.includes('TOO_LATE')) return 'Time ran out before your answer arrived.';
    if (text.includes('ALREADY_ANSWERED')) return 'You have already answered this question.';
    if (text.includes('NOT_REVEALED')) return 'Wait for the answer reveal before moving on.';
    if (text.includes('MATCH_NOT_FOUND')) return 'This match could not be found.';
    return text;
  }
  if (error instanceof Error) return error.message;
  return 'Something went wrong. Please try again.';
}

function playerName(displayName: string): string {
  const clean = displayName.trim().replace(/[\u0000-\u001f\u007f]/g, '').slice(0, 24);
  return clean.length >= 2 ? clean : 'Guest';
}

export default function App() {
  const [screen, setScreen] = useState<Screen>('home');
  const [displayName, setDisplayName] = useState(() => localStorage.getItem(DISPLAY_NAME_KEY) || '');
  const [userId, setUserId] = useState<string | null>(null);
  const [rooms, setRooms] = useState<PublicRoom[]>([]);
  const [room, setRoom] = useState<RoomSnapshot | null>(null);
  const [roomCodeInput, setRoomCodeInput] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<Notice>(null);
  const [guestReady, setGuestReady] = useState(false);
  const [rejoinPrompt, setRejoinPrompt] = useState<SavedRoom | null>(null);
  const [connection, setConnection] = useState<'connected' | 'connecting' | 'offline'>('connecting');
  const [clockOffset, setClockOffset] = useState(0);
  const [playable, setPlayable] = useState<string[]>([]);
  const [, setTick] = useState(0);
  const advancing = useRef(false);

  const isHost = Boolean(room && userId && room.room.host_id === userId);
  const myPlayer = useMemo(
    () => room?.players.find((player) => player.user_id === userId),
    [room, userId],
  );

  const clearSavedRoom = useCallback(() => {
    localStorage.removeItem(ACTIVE_ROOM_KEY);
    setRejoinPrompt(null);
  }, []);

  const loadRoom = useCallback(async (roomId: string, silent = false) => {
    try {
      const snapshot = await gameApi.getRoom(roomId);
      if (snapshot.room.status === 'closed' || !snapshot.players.some((player) => player.user_id === userId)) {
        clearSavedRoom();
        setRoom(null);
        setScreen('lobby');
        setNotice({ text: 'That room has closed or your guest has left it.', tone: 'info' });
        return;
      }
      setRoom(snapshot);
      const offset = Date.parse(snapshot.room.server_now) - Date.now();
      setClockOffset(Number.isFinite(offset) ? offset : 0);
      setConnection('connected');
    } catch (error) {
      if (!silent) setNotice({ text: friendlyError(error), tone: 'error' });
      if (String(error instanceof Error ? error.message : error).includes('NOT_A_ROOM_MEMBER')) {
        clearSavedRoom();
        setRoom(null);
        setScreen('lobby');
      }
      setConnection('offline');
    }
  }, [clearSavedRoom, userId]);

  const loadRooms = useCallback(async (silent = false) => {
    try {
      const result = await gameApi.listRooms();
      setRooms(result.rooms || []);
      setConnection('connected');
    } catch (error) {
      if (!silent) setNotice({ text: friendlyError(error), tone: 'error' });
      setConnection('offline');
    }
  }, []);

  const enterRoom = useCallback(async (saved: SavedRoom) => {
    localStorage.setItem(ACTIVE_ROOM_KEY, JSON.stringify(saved));
    setRejoinPrompt(null);
    setRoomCodeInput(saved.code);
    setScreen('room');
    await loadRoom(saved.id);
  }, [loadRoom]);

  async function ensureGuest(): Promise<string> {
    if (!supabase) throw new Error('Supabase is not configured yet. Follow README.md to connect the project.');
    const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
    if (sessionError) throw sessionError;
    let currentUserId = sessionData.session?.user.id;
    if (!currentUserId) {
      const { data, error } = await supabase.auth.signInAnonymously();
      if (error) throw error;
      currentUserId = data.user?.id;
    }
    if (!currentUserId) throw new Error('Could not create a guest session. Please try again.');
    setUserId(currentUserId);
    setGuestReady(true);
    return currentUserId;
  }

  async function startMultiplayer() {
    const name = playerName(displayName);
    setDisplayName(name);
    localStorage.setItem(DISPLAY_NAME_KEY, name);
    setBusy(true);
    setNotice(null);
    try {
      await ensureGuest();
      setScreen('lobby');
      await loadRooms();
    } catch (error) {
      setNotice({ text: friendlyError(error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function createRoom() {
    setBusy(true);
    setNotice(null);
    try {
      const result = await gameApi.createRoom(playerName(displayName));
      await enterRoom({ id: result.room_id, code: result.code });
    } catch (error) {
      setNotice({ text: friendlyError(error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function joinRoom(code: string) {
    const normalized = code.trim().toUpperCase();
    if (!/^[A-Z0-9]{6}$/.test(normalized)) {
      setNotice({ text: 'Enter a valid six-character room code.', tone: 'error' });
      return;
    }
    setBusy(true);
    setNotice(null);
    try {
      const result = await gameApi.joinRoom(normalized, playerName(displayName));
      await enterRoom({ id: result.room_id, code: result.code });
    } catch (error) {
      setNotice({ text: friendlyError(error), tone: 'error' });
      await loadRooms(true);
    } finally {
      setBusy(false);
    }
  }

  async function toggleReady() {
    if (!room || !myPlayer || busy) return;
    setBusy(true);
    setNotice(null);
    try {
      await gameApi.setReady(room.room.id, !myPlayer.is_ready);
      await loadRoom(room.room.id, true);
    } catch (error) {
      setNotice({ text: friendlyError(error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function toggleVote(slug: string) {
    if (!room || !myPlayer || busy) return;
    const current = myPlayer.category_votes ?? [];
    let next: string[];
    if (current.includes(slug)) {
      next = current.filter((item) => item !== slug);
    } else if (current.length >= 2) {
      setNotice({ text: 'You can vote for up to two categories. Tap one of your picks to remove it first.', tone: 'info' });
      return;
    } else {
      next = [...current, slug];
    }
    setBusy(true);
    setNotice(null);
    try {
      await gameApi.setCategoryVotes(room.room.id, next);
      await loadRoom(room.room.id, true);
    } catch (error) {
      setNotice({ text: friendlyError(error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function startMatch() {
    if (!room || !isHost || busy) return;
    setBusy(true);
    setNotice(null);
    try {
      await gameApi.startCountdown(room.room.id);
      await loadRoom(room.room.id, true);
    } catch (error) {
      setNotice({ text: friendlyError(error), tone: 'error' });
    } finally {
      setBusy(false);
    }
  }

  async function leaveRoom() {
    if (!room) {
      setScreen('lobby');
      return;
    }
    setBusy(true);
    try {
      await gameApi.leaveRoom(room.room.id);
    } catch (error) {
      setNotice({ text: friendlyError(error), tone: 'error' });
    } finally {
      clearSavedRoom();
      setRoom(null);
      setScreen('lobby');
      setBusy(false);
      await loadRooms(true);
    }
  }

  async function copyRoomCode() {
    if (!room) return;
    try {
      await navigator.clipboard.writeText(room.room.code);
      setNotice({ text: 'Room code copied. Send it to your friends.', tone: 'success' });
    } catch {
      window.prompt('Copy this room code:', room.room.code);
    }
  }

  function handleCodeSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    void joinRoom(roomCodeInput);
  }

  useEffect(() => {
    const hadTabSession = sessionStorage.getItem(TAB_SESSION_KEY) === '1';
    sessionStorage.setItem(TAB_SESSION_KEY, '1');
    if (!supabase) {
      setConnection('offline');
      return;
    }
    let cancelled = false;
    void supabase.auth.getSession().then(async ({ data }) => {
      if (cancelled || !data.session) return;
      const restoredUserId = data.session.user.id;
      setUserId(restoredUserId);
      setGuestReady(true);
      const saved = readSavedRoom();
      if (!saved) return;
      if (!hadTabSession) {
        setRejoinPrompt(saved);
        return;
      }
      try {
        const snapshot = await gameApi.getRoom(saved.id);
        if (cancelled) return;
        if (snapshot.room.status === 'closed' || !snapshot.players.some((player) => player.user_id === restoredUserId)) {
          clearSavedRoom();
          return;
        }
        setRoom(snapshot);
        setRoomCodeInput(snapshot.room.code);
        setScreen('room');
        setConnection('connected');
      } catch {
        if (!cancelled) {
          clearSavedRoom();
          setNotice({ text: 'Your previous room is no longer available. You can join another room.', tone: 'info' });
        }
      }
    }).catch(() => setConnection('offline'));
    return () => { cancelled = true; };
  }, [clearSavedRoom]);

  useEffect(() => {
    if (screen !== 'lobby' || !guestReady) return;
    void loadRooms(true);
    const timer = window.setInterval(() => void loadRooms(true), 5000);
    return () => window.clearInterval(timer);
  }, [guestReady, loadRooms, screen]);

  const activeRoomId = room?.room.id;
  useEffect(() => {
    if (!activeRoomId) return;
    gameApi.soloCategories().then((result) => setPlayable(result.categories)).catch(() => undefined);
  }, [activeRoomId]);
  useEffect(() => {
    if (screen !== 'room' || !activeRoomId || !supabase) return;
    const roomId = activeRoomId;
    const client = supabase;
    let refreshTimer: number | undefined;
    const channel = client
      .channel(`room:${roomId}`, { config: { private: true } })
      .on('broadcast', { event: 'room_updated' }, () => {
        // Several changes can arrive together, so wait a moment and refresh once.
        window.clearTimeout(refreshTimer);
        refreshTimer = window.setTimeout(() => { void loadRoom(roomId, true); }, 250);
      })
      .subscribe((status) => {
        if (status === 'SUBSCRIBED') setConnection('connected');
        if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') setConnection('offline');
      });
    const poll = window.setInterval(() => void loadRoom(roomId, true), 8000);
    const heartbeat = window.setInterval(() => {
      void gameApi.heartbeat(roomId).catch(() => setConnection('offline'));
    }, 15000);
    return () => {
      window.clearTimeout(refreshTimer);
      window.clearInterval(poll);
      window.clearInterval(heartbeat);
      void client.removeChannel(channel);
    };
  }, [activeRoomId, loadRoom, screen]);

  const readyCount = room?.players.filter((player) => player.is_ready).length || 0;
  const roomStatus = room?.room.status;
  const countdownEndsAt = room?.room.countdown_ends_at ? Date.parse(room.room.countdown_ends_at) : null;

  // While the countdown runs, redraw the timer and ask the server to move on once it reaches zero.
  useEffect(() => {
    if (screen !== 'room' || roomStatus !== 'countdown' || !activeRoomId) return;
    const roomId = activeRoomId;
    const timer = window.setInterval(() => {
      setTick((value) => value + 1);
      if (countdownEndsAt === null || advancing.current) return;
      if (Date.now() + clockOffset < countdownEndsAt) return;
      advancing.current = true;
      gameApi.advanceCountdown(roomId)
        .then(async (result) => {
          if (result.status === 'waiting') {
            setNotice({ text: 'Fewer than two players were ready, so the room is back to waiting.', tone: 'info' });
          }
          await loadRoom(roomId, true);
        })
        .catch(() => undefined)
        .finally(() => { advancing.current = false; });
    }, 250);
    return () => window.clearInterval(timer);
  }, [activeRoomId, clockOffset, countdownEndsAt, loadRoom, roomStatus, screen]);

  const secondsLeft = countdownEndsAt === null ? 0 : Math.max(0, Math.ceil((countdownEndsAt - (Date.now() + clockOffset)) / 1000));
  const myVotes = myPlayer?.category_votes ?? [];
  const sports = useMemo(() => Array.from(new Set(launchCategories.map((category) => category.sport))), []);
  const voteCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const player of room?.players ?? []) {
      if (!player.is_ready) continue;
      for (const slug of player.category_votes ?? []) counts[slug] = (counts[slug] || 0) + 1;
    }
    return counts;
  }, [room]);
  const chosenCategory = launchCategories.find((category) => category.slug === room?.room.selected_categories?.[0]);

  return (
    <main className="app-shell">
      <header className="topbar">
        <button className="brand-button" onClick={() => { if (screen === 'room') return; setScreen('home'); setNotice(null); }} aria-label="SportStack home">
          <span className="brand-mark">S</span>
          <span className="brand-name">sport<span>stack</span><i>.</i></span>
        </button>
        <div className="topbar-right">
          <span className={`connection-dot ${connection}`} aria-hidden="true" />
          <span className="connection-label">{connection === 'connected' ? 'Connected' : connection === 'connecting' ? 'Connecting' : 'Offline'}</span>
          <span className="version-label">PHASE 3</span>
        </div>
      </header>

      {notice && (
        <div className={`notice notice-${notice.tone}`} role="status">
          <span>{notice.text}</span>
          <button className="notice-dismiss" onClick={() => setNotice(null)} aria-label="Dismiss notice">×</button>
        </div>
      )}

      {!isSupabaseConfigured && (
        <div className="setup-banner" role="status">
          <strong>Online play needs a one-time connection.</strong>
          <span>Follow the README to create a Supabase project, apply the migration and add your local environment variables. The screens are ready to preview, but room actions will not work until setup is complete.</span>
        </div>
      )}

      {screen === 'home' && (
        <section className="home-view">
          <div className="hero-copy">
            <div className="eyebrow"><span className="eyebrow-line" /> THE SPORTS QUIZ FOR CURIOUS FANS</div>
            <h1>Know your sport.<br /><span>Prove your knowledge.</span></h1>
            <p className="hero-description">From iconic finals to the details only real fans remember. Pick your game and take your place.</p>
          </div>

          {rejoinPrompt && (
            <div className="rejoin-card">
              <div>
                <span className="small-label">YOUR LAST ROOM</span>
                <strong>Room {rejoinPrompt.code}</strong>
                <p>We found a room from your previous visit.</p>
              </div>
              <button className="button button-primary" onClick={() => void enterRoom(rejoinPrompt)}>Rejoin room <span>→</span></button>
            </div>
          )}

          <div className="name-entry">
            <label htmlFor="display-name">Choose your display name</label>
            <input
              id="display-name"
              value={displayName}
              onChange={(event) => setDisplayName(event.target.value.slice(0, 24))}
              maxLength={24}
              minLength={2}
              placeholder="e.g. TheTactician"
              autoComplete="nickname"
            />
            <span className="input-help">2–24 characters. You can use a nickname; no account form needed.</span>
          </div>

          <div className="mode-grid">
            <button className="mode-card solo-card" onClick={() => setScreen('solo')}>
              <span className="mode-icon">◎</span>
              <span className="mode-text"><strong>Single Player</strong><small>Take on the Solo Challenge</small></span>
              <span className="mode-arrow">↗</span>
              <span className="mode-tag">SOLO</span>
            </button>
            <button className="mode-card multiplayer-card" onClick={() => void startMultiplayer()} disabled={busy}>
              <span className="mode-icon">↗</span>
              <span className="mode-text"><strong>Multiplayer</strong><small>Find a room. Challenge your friends.</small></span>
              <span className="mode-arrow">→</span>
              <span className="mode-tag">LIVE</span>
            </button>
          </div>
          <div className="home-footnote"><span className="neon-dot" /> 7 sports <span>·</span> 14 categories <span>·</span> Made for fans, by fans</div>
        </section>
      )}

      {screen === 'solo' && (
        <SoloChallenge ensureGuest={ensureGuest} onBack={() => setScreen('home')} describeError={friendlyError} />
      )}

      {screen === 'lobby' && (
        <section className="subpage">
          <button className="back-link" onClick={() => { setScreen('home'); setNotice(null); }}>← Back to home</button>
          <div className="lobby-heading">
            <div>
              <div className="eyebrow">MULTIPLAYER</div>
              <h1 className="page-title">Public rooms<span className="title-period">.</span></h1>
              <p className="page-description">Find an open room or create one for your friends.</p>
            </div>
            <button className="button button-primary create-button" disabled={busy || !isSupabaseConfigured} onClick={() => void createRoom()}>＋ Create room</button>
          </div>

          <div className="join-code-panel">
            <div className="join-code-copy"><strong>Have a room code?</strong><span>Enter the six-character code your friend shared.</span></div>
            <form className="join-code-form" onSubmit={handleCodeSubmit}>
              <label className="visually-hidden" htmlFor="room-code">Room code</label>
              <input id="room-code" value={roomCodeInput} onChange={(event) => setRoomCodeInput(event.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 6))} placeholder="ABC123" maxLength={6} autoCapitalize="characters" />
              <button className="button button-secondary" disabled={busy || roomCodeInput.length !== 6 || !isSupabaseConfigured}>Join room</button>
            </form>
          </div>

          <div className="section-heading"><h2>Open rooms</h2><span className="room-count">{rooms.length} available</span></div>
          {rooms.length === 0 ? (
            <div className="empty-state">
              <span className="empty-icon">⌁</span>
              <strong>No open rooms right now</strong>
              <p>Create a room and invite friends, or check back in a moment.</p>
              <button className="button button-secondary" disabled={busy || !isSupabaseConfigured} onClick={() => void loadRooms()}>Refresh rooms</button>
            </div>
          ) : (
            <div className="rooms-grid">
              {rooms.map((publicRoom) => (
                <article className="room-card" key={publicRoom.id}>
                  <div className="room-card-top"><span className="room-status"><i /> WAITING</span><span className="room-player-count">{publicRoom.player_count}/4 players</span></div>
                  <div className="room-card-code">{publicRoom.code}</div>
                  <div className="room-player-preview">
                    {publicRoom.players.slice(0, 4).map((player) => <span className="mini-player" key={`${player.display_name}-${player.player_tag}`}>{player.display_name}<small>#{player.player_tag}</small></span>)}
                  </div>
                  <div className="room-card-bottom"><span>{publicRoom.players.filter((player) => player.is_ready).length} ready</span><button className="text-button" disabled={busy || publicRoom.player_count >= 4 || !isSupabaseConfigured} onClick={() => void joinRoom(publicRoom.code)}>Join room →</button></div>
                </article>
              ))}
            </div>
          )}
          <p className="subpage-footnote">Rooms update automatically. Once in a room, vote for categories and the host starts the match.</p>
        </section>
      )}

      {screen === 'room' && room && (room.room.status === 'in_progress' || room.room.status === 'results') && (
        <section className="subpage room-view">
          <MultiplayerMatch roomId={room.room.id} userId={userId ?? ''} refreshKey={room} onLeave={() => void leaveRoom()} describeError={friendlyError} />
        </section>
      )}

      {screen === 'room' && room && (room.room.status === 'waiting' || room.room.status === 'countdown') && (
        <section className="subpage room-view">
          <button className="back-link" onClick={() => void leaveRoom()}>← Leave room</button>
          <div className="room-heading">
            <div>
              <div className="eyebrow">{room.room.status === 'waiting' ? 'WAITING ROOM · PUBLIC' : room.room.status === 'countdown' ? 'MATCH STARTING' : 'MATCH READY'}</div>
              <h1 className="page-title">{room.room.status === 'waiting' ? 'Ready to play' : room.room.status === 'countdown' ? 'Get set' : 'Here we go'}<span className="title-period">.</span></h1>
              <p className="page-description">{room.room.status === 'waiting' ? 'Vote for up to two categories, then get ready.' : chosenCategory ? `Category: ${chosenCategory.sport}, ${chosenCategory.label}.` : 'The category has been chosen.'}</p>
            </div>
            <div className="room-code-box"><span>ROOM CODE</span><strong>{room.room.code}</strong><button onClick={() => void copyRoomCode()}>Copy code ↗</button></div>
          </div>
          <div className="room-summary"><div><strong>{room.players.length} / 4</strong><span>Players</span></div><div><strong>{readyCount} / {room.players.length}</strong><span>Ready</span></div><div><strong>{isHost ? 'Host' : 'Guest'}</strong><span>Your role</span></div></div>
          <div className="section-heading"><h2>Players in this room</h2><span className="room-count">{room.players.length} joined</span></div>
          <div className="players-list">
            {room.players.map((player) => (
              <div className="player-row" key={player.user_id}>
                <div className="player-avatar">{player.display_name.trim().slice(0, 1).toUpperCase()}</div>
                <div className="player-name-block"><strong>{player.display_name} <small>#{player.player_tag}</small></strong><span>{player.is_host ? 'Room host' : player.user_id === userId ? 'You' : 'Guest player'}</span></div>
                <span className={`ready-badge ${player.is_ready ? 'is-ready' : ''}`}><i />{player.is_ready ? 'Ready' : 'Not ready'}</span>
              </div>
            ))}
            {Array.from({ length: Math.max(0, 4 - room.players.length) }).map((_, index) => (
              <div className="player-row player-placeholder" key={`open-${index}`}><div className="player-avatar placeholder-avatar">＋</div><div className="player-name-block"><strong>Open spot</strong><span>Room can accept another player</span></div><span className="waiting-label">Waiting</span></div>
            ))}
          </div>
          {room.room.status === 'waiting' && (
            <>
              <div className="section-heading"><h2>Vote for categories</h2><span className="room-count">{myVotes.length} / 2 picked</span></div>
              <p className="vote-help">Pick up to two. The category with the most votes from ready players is played. Ties are settled at random.</p>
              <div className="category-groups">
                {sports.map((sport) => (
                  <div className="category-group" key={sport}>
                    <div className="category-sport">{sport}</div>
                    <div className="category-chips">
                      {launchCategories.filter((category) => category.sport === sport).map((category) => {
                        const selected = myVotes.includes(category.slug);
                        const count = voteCounts[category.slug] || 0;
                        return (
                          <button key={category.slug} type="button" className={`category-chip ${selected ? 'is-selected' : ''}`} aria-pressed={selected} disabled={busy || !myPlayer || (playable.length > 0 && !playable.includes(category.slug))} onClick={() => void toggleVote(category.slug)}>
                            <span>{category.label}</span>
                            {playable.length > 0 && !playable.includes(category.slug) && <b>Soon</b>}
                            {count > 0 && <b title="Votes from ready players">{count}</b>}
                          </button>
                        );
                      })}
                    </div>
                  </div>
                ))}
              </div>
              <div className="room-actions">
                <button className={`button ${myPlayer?.is_ready ? 'button-secondary' : 'button-primary'}`} disabled={busy || !myPlayer} onClick={() => void toggleReady()}>{myPlayer?.is_ready ? 'I’m not ready' : 'I’m ready'}</button>
                {isHost && <button className="button button-primary" disabled={busy || readyCount < 2} onClick={() => void startMatch()}>Start match</button>}
                <button className="button button-quiet" disabled={busy} onClick={() => void copyRoomCode()}>Copy invite code</button>
              </div>
              <p className="vote-help">{isHost ? (readyCount >= 2 ? 'Everything is set. Start the match whenever you are ready.' : 'You need at least two ready players before you can start the match.') : 'The host starts the match once at least two players are ready.'}</p>
            </>
          )}
          {room.room.status === 'countdown' && (
            <div className="countdown-panel" role="status" aria-live="polite">
              <span>Starting in</span>
              <strong>{secondsLeft}</strong>
              <p>{chosenCategory ? `${chosenCategory.sport}: ${chosenCategory.label}` : 'Category chosen'}</p>
            </div>
          )}
          <p className="subpage-footnote">Keep this tab open. If you refresh, SportStack will try to reconnect you to this room automatically.</p>
        </section>
      )}

      <footer className="site-footer"><span>SPORTSTACK <i>©</i> 2026</span><span>BUILT FOR THE LOVE OF SPORT</span></footer>
    </main>
  );
}
