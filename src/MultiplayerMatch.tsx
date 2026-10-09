import { useCallback, useEffect, useRef, useState } from 'react';
import { launchCategories } from './data/categories';
import { gameApi } from './lib/gameApi';
import type { MatchInProgress, MatchPlayer, MatchResult, MatchState } from './types';

type Props = {
  roomId: string;
  userId: string;
  refreshKey: unknown;
  onLeave: () => void;
  describeError: (error: unknown) => string;
};

const TIMER_MS = 15000;

function categoryName(slug: string): string {
  const match = launchCategories.find((category) => category.slug === slug);
  return match ? `${match.sport}: ${match.label}` : slug;
}

function deltaText(delta: number): string {
  if (delta > 0) return `+${delta}`;
  return `${delta}`;
}

function pointsText(points: number, answered: boolean): string {
  if (points > 0) return `+${points} points`;
  if (points < 0) return `${points} points`;
  return answered ? '0 points' : '0 points (time ran out)';
}

function Scoreboard({ players, userId, phase, results }: { players: MatchPlayer[]; userId: string; phase?: string; results?: MatchResult[] }) {
  return (
    <div className="scoreboard">
      {players.map((player, index) => {
        const result = results?.find((item) => item.user_id === player.user_id);
        let status = '';
        if (phase === 'answering') status = player.answered ? 'Locked in' : 'Thinking…';
        if (phase === 'reveal' && result) status = `${deltaText(result.delta)}`;
        return (
          <div className={`score-row ${player.user_id === userId ? 'is-you' : ''}`} key={player.user_id}>
            <span className="score-rank">{index + 1}</span>
            <span className="score-name">{player.display_name}{player.user_id === userId ? ' (you)' : ''}</span>
            <span className="score-status">{status}</span>
            <span className="score-streak">Streak {player.streak}</span>
            <strong className="score-points">{player.score}</strong>
          </div>
        );
      })}
    </div>
  );
}

export default function MultiplayerMatch({ roomId, userId, refreshKey, onLeave, describeError }: Props) {
  const [state, setState] = useState<MatchState | null>(null);
  const [phaseEndsAt, setPhaseEndsAt] = useState(0);
  const [pending, setPending] = useState<{ position: number; answer: string } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [, setTick] = useState(0);
  const fetching = useRef(false);
  const helpers = useRef({ describeError });
  helpers.current = { describeError };

  const refresh = useCallback(async () => {
    if (fetching.current) return;
    fetching.current = true;
    try {
      const next = await gameApi.matchState(roomId);
      setState(next);
      if (next.status === 'in_progress') setPhaseEndsAt(Date.now() + next.ms_left);
      setError(null);
    } catch (caught) {
      setError(helpers.current.describeError(caught));
      setPhaseEndsAt(Date.now() + 2000);
    } finally {
      fetching.current = false;
    }
  }, [roomId]);

  // Refresh on mount and whenever the room reports a change.
  useEffect(() => {
    void refresh();
  }, [refresh, refreshKey]);

  // Redraw the timer, and ask the server for the next step as soon as a phase ends.
  const inProgress = state?.status === 'in_progress';
  useEffect(() => {
    if (!inProgress) return;
    const timer = window.setInterval(() => {
      setTick((value) => value + 1);
      if (Date.now() >= phaseEndsAt) void refresh();
    }, 250);
    return () => window.clearInterval(timer);
  }, [inProgress, phaseEndsAt, refresh]);

  async function choose(question: MatchInProgress, option: string) {
    if (question.phase !== 'answering') return;
    if (question.my_answer || (pending && pending.position === question.position)) return;
    setPending({ position: question.position, answer: option });
    setError(null);
    try {
      await gameApi.matchAnswer(roomId, option);
    } catch (caught) {
      const text = caught instanceof Error ? caught.message : '';
      if (text.includes('TOO_LATE') || text.includes('ALREADY_ANSWERED')) {
        void refresh();
      } else {
        setPending(null);
        setError(describeError(caught));
      }
    }
  }

  const errorBanner = error && (
    <div className="notice notice-error" role="alert">
      <span>{error}</span>
      <button className="notice-dismiss" aria-label="Dismiss message" onClick={() => setError(null)}>×</button>
    </div>
  );

  if (!state) {
    return (
      <>
        <div className="eyebrow">MULTIPLAYER</div>
        <h1 className="page-title">Loading the match<span className="title-period">.</span></h1>
        {errorBanner}
        <button className="back-link" onClick={onLeave}>← Leave room</button>
      </>
    );
  }

  // ---------- Final results ----------
  if (state.status === 'completed') {
    const topScore = state.players.length > 0 ? state.players[0].score : 0;
    const winners = state.players.filter((player) => player.score === topScore);
    const headline = winners.length > 1
      ? `It's a tie between ${winners.map((player) => player.display_name).join(' and ')}`
      : `${winners[0]?.display_name ?? 'Nobody'} wins`;
    return (
      <>
        <div className="eyebrow">{categoryName(state.category_slug).toUpperCase()}</div>
        <h1 className="page-title">Match complete<span className="title-period">.</span></h1>
        <p className="page-description">{headline} with {topScore} points.</p>
        {errorBanner}
        <div className="section-heading"><h2>Final standings</h2></div>
        <div className="scoreboard">
          {state.players.map((player, index) => (
            <div className={`score-row ${player.user_id === userId ? 'is-you' : ''}`} key={player.user_id}>
              <span className="score-rank">{index + 1}</span>
              <span className="score-name">{player.display_name}{player.user_id === userId ? ' (you)' : ''}</span>
              <span className="score-status">{player.correct_answers} / 15 correct</span>
              <span className="score-streak">Best streak {player.longest_streak}</span>
              <strong className="score-points">{player.score}</strong>
            </div>
          ))}
        </div>
        <div className="room-actions">
          <button className="button button-primary" onClick={onLeave}>Leave room</button>
        </div>
        <div className="section-heading"><h2>Your answer review</h2></div>
        <div className="review-list">
          {state.review.map((item) => (
            <div className={`review-item ${item.is_correct ? 'is-correct' : 'is-wrong'}`} key={item.position}>
              <div className="review-top">
                <span>Question {item.position} · {item.difficulty}</span>
                <b>{pointsText(item.points_awarded, item.selected_answer !== null)}</b>
              </div>
              <p className="review-prompt">{item.prompt}</p>
              <p className="review-line">Your answer: <strong>{item.selected_answer ?? 'No answer'}</strong></p>
              {!item.is_correct && <p className="review-line">Correct answer: <strong>{item.correct_answer}</strong></p>}
              <p className="review-explanation">{item.explanation}</p>
              <a className="source-link" href={item.source_url} target="_blank" rel="noopener noreferrer">Source: {item.source_title}</a>
            </div>
          ))}
        </div>
      </>
    );
  }

  const question: MatchInProgress = state;
  const remaining = Math.max(0, phaseEndsAt - Date.now());
  const secondsLeft = Math.ceil(remaining / 1000);
  const selected = question.my_answer ?? (pending && pending.position === question.position ? pending.answer : null);

  // ---------- Get ready ----------
  if (question.phase === 'get_ready') {
    return (
      <>
        <div className="eyebrow">{categoryName(question.category_slug).toUpperCase()}</div>
        <h1 className="page-title">Get ready<span className="title-period">.</span></h1>
        {errorBanner}
        <div className="countdown-panel" role="status" aria-live="polite">
          <span>Question {question.position} starts in</span>
          <strong>{secondsLeft}</strong>
          <p>15 questions, 15 seconds each</p>
        </div>
        <Scoreboard players={question.players} userId={userId} />
      </>
    );
  }

  const revealed = question.phase === 'reveal';
  const myResult = question.results?.find((item) => item.user_id === userId);
  const me = question.players.find((player) => player.user_id === userId);

  return (
    <>
      <div className="solo-hud">
        <span>Question {question.position} / {question.total}</span>
        <span className={`difficulty-pill diff-${question.difficulty}`}>{question.difficulty}</span>
        <span>Your score <b>{me?.score ?? 0}</b></span>
        <span>Streak <b>{me?.streak ?? 0}</b></span>
      </div>

      {!revealed && (
        <div className="timer-wrap" role="timer" aria-label={`${secondsLeft} seconds left`}>
          <div className="timer-track"><div className="timer-fill" style={{ width: `${Math.min(100, (remaining / TIMER_MS) * 100)}%` }} /></div>
          <span className="timer-text">{secondsLeft}s</span>
        </div>
      )}

      {errorBanner}
      <h2 className="question-prompt">{question.prompt}</h2>

      <div className="option-list">
        {(question.options ?? []).map((option) => {
          let stateClass = '';
          if (revealed) {
            if (option === question.correct_answer) stateClass = 'is-correct';
            else if (option === question.my_answer) stateClass = 'is-wrong';
            else stateClass = 'is-dim';
          } else if (option === selected) {
            stateClass = 'is-locked';
          }
          return (
            <button
              key={option}
              type="button"
              className={`option-button ${stateClass}`}
              disabled={revealed || selected !== null}
              onClick={() => void choose(question, option)}
            >
              {option}
            </button>
          );
        })}
      </div>

      {!revealed && selected && <p className="vote-help">Answer locked. Everyone sees the result when the timer ends.</p>}

      {revealed && (
        <div className={`reveal-box ${myResult?.is_correct ? 'is-correct' : 'is-wrong'}`}>
          <strong>
            {myResult?.is_correct ? 'Correct!' : question.my_answer ? 'Not quite.' : 'Time ran out.'}{' '}
            {pointsText(myResult?.delta ?? 0, question.my_answer !== null && question.my_answer !== undefined)}
          </strong>
          {!myResult?.is_correct && <p>The correct answer was <b>{question.correct_answer}</b>.</p>}
          <p>{question.explanation}</p>
          {question.source_url && (
            <a className="source-link" href={question.source_url} target="_blank" rel="noopener noreferrer">Source: {question.source_title}</a>
          )}
          <p className="reveal-next">{question.is_last ? 'Final results' : 'Next question'} in {secondsLeft}s</p>
        </div>
      )}

      <Scoreboard players={question.players} userId={userId} phase={question.phase} results={question.results} />
    </>
  );
}
