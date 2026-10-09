export type RoomPlayer = {
  user_id: string;
  display_name: string;
  player_tag: string;
  is_ready: boolean;
  is_host: boolean;
  joined_at: string;
  category_votes: string[];
};

export type PublicRoom = {
  id: string;
  code: string;
  status: 'waiting' | 'countdown' | 'in_progress' | 'results' | 'closed';
  host_id: string;
  max_players: number;
  created_at: string;
  players: Pick<RoomPlayer, 'display_name' | 'player_tag' | 'is_ready'>[];
  player_count: number;
};

export type RoomSnapshot = {
  room: {
    id: string;
    code: string;
    status: 'waiting' | 'countdown' | 'in_progress' | 'results' | 'closed';
    host_id: string;
    max_players: number;
    created_at: string;
    selected_categories: string[];
    countdown_ends_at: string | null;
    server_now: string;
  };
  players: RoomPlayer[];
};

export type SavedRoom = { id: string; code: string };

export type SoloReviewItem = {
  position: number;
  difficulty: 'easy' | 'medium' | 'hard';
  prompt: string;
  selected_answer: string | null;
  correct_answer: string;
  is_correct: boolean;
  points_awarded: number;
  explanation: string;
  source_title: string;
  source_url: string;
};

export type SoloQuestionState = {
  status: 'in_progress';
  phase: 'answering' | 'reveal';
  position: number;
  total: number;
  difficulty: 'easy' | 'medium' | 'hard';
  prompt: string;
  options: string[];
  selected_answer: string | null;
  ms_left?: number;
  correct_answer?: string;
  is_correct?: boolean;
  points_awarded?: number;
  explanation?: string;
  source_title?: string;
  source_url?: string;
  score: number;
  streak: number;
  is_last?: boolean;
};

export type SoloFinishedState = {
  status: 'finished';
  category_slug: string;
  score: number;
  correct_count: number;
  total: number;
  accuracy: number;
  best_streak: number;
  review: SoloReviewItem[];
};

export type SoloState = SoloQuestionState | SoloFinishedState;

export type MatchPlayer = {
  user_id: string;
  display_name: string;
  player_tag: string;
  score: number;
  streak: number;
  longest_streak: number;
  correct_answers: number;
  answered: boolean;
};

export type MatchResult = {
  user_id: string;
  selected_answer: string | null;
  is_correct: boolean;
  delta: number;
};

export type MatchInProgress = {
  status: 'in_progress';
  phase: 'get_ready' | 'answering' | 'reveal';
  position: number;
  total: number;
  category_slug: string;
  ms_left: number;
  players: MatchPlayer[];
  difficulty?: 'easy' | 'medium' | 'hard';
  prompt?: string;
  options?: string[];
  my_answer?: string | null;
  correct_answer?: string;
  explanation?: string;
  source_title?: string;
  source_url?: string;
  results?: MatchResult[];
  is_last?: boolean;
};

export type MatchCompleted = {
  status: 'completed';
  category_slug: string;
  players: MatchPlayer[];
  review: SoloReviewItem[];
};

export type MatchState = MatchInProgress | MatchCompleted;
