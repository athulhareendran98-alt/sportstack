import type { MatchState, PublicRoom, RoomSnapshot, SoloState } from '../types';
import { supabase } from './supabase';

export class GameApiError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GameApiError';
  }
}

async function invoke<T>(action: string, payload: Record<string, unknown> = {}): Promise<T> {
  if (!supabase) throw new GameApiError('Supabase is not configured yet. Follow the setup guide in README.md.');
  const { data, error } = await supabase.functions.invoke('game-api', {
    body: { action, ...payload },
  });
  if (error) {
    const context = (error as { context?: { json?: () => Promise<{ error?: string }> } }).context;
    let message = error.message || 'The request could not be completed.';
    try {
      const body = await context?.json?.();
      if (body?.error) message = body.error;
    } catch {
      // Keep the original message when the response is not JSON.
    }
    throw new GameApiError(message);
  }
  if (data?.error) throw new GameApiError(String(data.error));
  return data as T;
}

export const gameApi = {
  async createRoom(displayName: string) {
    return invoke<{ room_id: string; code: string }>('create_room', { displayName });
  },
  async listRooms() {
    return invoke<{ rooms: PublicRoom[] }>('list_rooms');
  },
  async joinRoom(code: string, displayName: string) {
    return invoke<{ room_id: string; code: string }>('join_room', { code, displayName });
  },
  async getRoom(roomId: string) {
    return invoke<RoomSnapshot>('room_snapshot', { roomId });
  },
  async setReady(roomId: string, isReady: boolean) {
    return invoke<{ ok: true }>('set_ready', { roomId, isReady });
  },
  async setCategoryVotes(roomId: string, categories: string[]) {
    return invoke<{ ok: true }>('set_category_votes', { roomId, categories });
  },
  async startCountdown(roomId: string) {
    return invoke<{ ok: true; category: string }>('start_countdown', { roomId });
  },
  async advanceCountdown(roomId: string) {
    return invoke<{ status: 'waiting' | 'countdown' | 'in_progress' | 'results' | 'closed' }>('advance_countdown', { roomId });
  },
  async soloCategories() {
    return invoke<{ categories: string[] }>('solo_categories');
  },
  async soloActive() {
    return invoke<{ attempt_id: string | null }>('solo_active');
  },
  async soloStart(category: string) {
    return invoke<{ attempt_id: string }>('solo_start', { category });
  },
  async soloState(attemptId: string) {
    return invoke<SoloState>('solo_state', { attemptId });
  },
  async soloAnswer(attemptId: string, answer: string) {
    return invoke<{ locked: true }>('solo_answer', { attemptId, answer });
  },
  async soloNext(attemptId: string) {
    return invoke<{ ok: true }>('solo_next', { attemptId });
  },
  async matchState(roomId: string) {
    return invoke<MatchState>('match_state', { roomId });
  },
  async matchAnswer(roomId: string, answer: string) {
    return invoke<{ locked: true }>('match_answer', { roomId, answer });
  },
  async leaveRoom(roomId: string) {
    return invoke<{ ok: true }>('leave_room', { roomId });
  },
  async heartbeat(roomId: string) {
    return invoke<{ ok: true }>('heartbeat', { roomId });
  },
};
