import { useCallback, useEffect, useRef, useState } from 'react';
import { launchCategories } from './data/categories';
import { gameApi } from './lib/gameApi';
import type { SoloQuestionState, SoloState } from './types';

type Props = {
  ensureGuest: () => Promise<string>;
  onBack: () => void;
  describeError: (error: unknown) => string;
};

const TIMER_MS = 15000;
const sports = Array.from(new Set(launchCategories.map((category) => category.sport)));

function categoryName(slug: string): string {
  const match = launchCategories.find((category) => category.slug === slug);
  return match ? `${match.sport}: ${match.label}` : slug;
}

function pointsText(points: number, answered: boolean): string {
  if (points > 0) return `+${points} points`;
  if (points < 0) return `${points} points`;
  return answered ? '0 points' : '0 points (time ran out)';
}

export default function SoloChallenge({ ensureGuest, onBack, describeError }: Props) {
  const [view, setView] = useState<'loading' | 'picking' | 'playing'>('loading');
  const [available, setAvailable] = useState<string[]>([]);
  const [attemptId, setAttemptId] = useState<string | null>(null);
  const [state, setState] = useState<SoloState | null>(null);
  const [deadline, setDeadline] = useState(0);
  const [, setTick] = useState(0);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pendingAnswer, setPendingAnswer] = useState<string | null>(null);
  const fetching = useRef(false);
  const helpers = useRef({ ensureGuest, describeError });
  helpers.current = { ensureGuest, describeError };

  const loadState = useCallback(async (id: string) => {
    const next = await gameApi.soloState(id);
    if (next.status === 'in_progress' && next.phase === 'answering') {
      setDeadline(Date.now() + (next.ms_left ?? 0));
    }
    setState(next);
    setPendingAnswer(null);
    setView('playing');
    return next;
  }, []);

  // Connect as a guest, see which categories are playable and resume any unfinished challenge.
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        await helpers.current.ensureGuest();
        const [categories, active] = await Promise.all([gameApi.soloCategories(), gameApi.soloActive()]);
        if (cancelled) return;
        setAvailable(categories.categories);
        if (active.attempt_id) {
          setAttemptId(active.attempt_id);
          await loadState(active.attempt_id);
        } else {
          setView('picking');
        }
      } catch (caught) {
        if (cancelled) return;
        setError(helpers.current.describeError(caught));
        setView('picking');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [loadState]);

  const answering = state?.status === 'in_progress' && state.phase === 'answering';

  // While a question is open: redraw the timer, and once it ends ask the server for the reveal.
  useEffect(() => {
    if (!answering || !attemptId) return;
    const id = attemptId;
    const timer = window.setInterval(() => {
      setTick((value) => value + 1);
      if (fetching.current || Date.now() < deadline) return;
      fetching.current = true;
      loadState(id)
        .catch((caught) => {
          setError(helpers.current.describeError(caught));
          setDeadline(Date.now() + 2000);
        })
        .finally(() => {
          fetching.current = false;
        });
    }, 250);
    return () => window.clearInterval(timer);
  }, [answering, attemptId, deadline, loadState]);

  async function start(slug: string) {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await helpers.current.ensureGuest();
      const created = await gameApi.soloStart(slug);
      setAttemptId(created.attempt_id);
      await loadState(created.attempt_id);
    } catch (caught) {
      setError(describeError(caught));
    } finally {
      setBusy(false);
    }
  }

  async function choose(option: string) {
    if (!attemptId || !state || state.status !== 'in_progress' || state.phase !== 'answering') return;
    if (state.selected_answer || pendingAnswer) return;
    setPendingAnswer(option);
    setError(null);
    try {
      await gameApi.soloAnswer(attemptId, option);
      setState((current) => (current && current.status === 'in_progress' ? { ...current, selected_answer: option } : current));
    } catch (caught) {
      const text = caught instanceof Error ? caught.message : '';
      if (text.includes('TOO_LATE') || text.includes('ALREADY_ANSWERED')) {
        await loadState(attemptId).catch(() => undefined);
      } else {
        setPendingAnswer(null);
        setError(describeError(caught));
      }
    }
  }

  async function next() {
    if (!attemptId || busy) return;
    setBusy(true);
    setError(null);
    try {
      await gameApi.soloNext(attemptId);
      await loadState(attemptId);
    } catch (caught) {
      setError(describeError(caught));
    } finally {
      setBusy(false);
    }
  }

  function playAgain() {
    setState(null);
    setAttemptId(null);
    setError(null);
    setView('picking');
  }

  const errorBanner = error && (
    <div className="notice notice-error" role="alert">
      <span>{error}</span>
      <button className="notice-dismiss" aria-label="Dismiss message" onClick={() => setError(null)}>×</button>
    </div>
  );

  // ---------- Category picker ----------
  if (view === 'loading') {
    return (
      <section className="subpage narrow-view">
        <button className="back-link" onClick={onBack}>← Back to home</button>
        <div className="eyebrow">SINGLE PLAYER</div>
        <h1 className="page-title">The Solo Challenge</h1>
        <p className="page-description">Getting your challenge ready…</p>
        {errorBanner}
      </section>
    );
  }

  if (view === 'picking' || !state) {
    return (
      <section className="subpage narrow-view">
        <button className="back-link" onClick={onBack}>← Back to home</button>
        <div className="page-icon">◎</div>
        <div className="eyebrow">SINGLE PLAYER</div>
        <h1 className="page-title">The Solo Challenge</h1>
        <p className="page-description">15 questions, 15 seconds each. Correct answers earn 100 points, with a 25 point bonus for every third correct answer in a row. A wrong answer costs 25 points. Pick a category to begin.</p>
        {errorBanner}
        <div className="category-groups">
          {sports.map((sport) => (
            <div className="category-group" key={sport}>
              <div className="category-sport">{sport}</div>
              <div className="category-chips">
                {launchCategories.filter((category) => category.sport === sport).map((category) => {
                  const playable = available.includes(category.slug);
                  return (
                    <button
                      key={category.slug}
                      type="button"
                      className="category-chip"
                      disabled={busy || !playable}
                      title={playable ? undefined : 'Questions coming soon'}
                      onClick={() => void start(category.slug)}
                    >
                      <span>{category.label}</span>
                      {!playable && <b>Soon</b>}
                    </button>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
        <button className="button button-secondary full-width" onClick={onBack}>Back to game modes</button>
      </section>
    );
  }

  // ---------- Results ----------
  if (state.status === 'finished') {
    return (
      <section className="subpage narrow-view">
        <div className="eyebrow">{categoryName(state.category_slug).toUpperCase()}</div>
        <h1 className="page-title">Challenge complete<span className="title-period">.</span></h1>
        {errorBanner}
        <div className="results-grid">
          <div className="result-card"><strong>{state.score}</strong><span>Final score</span></div>
          <div className="result-card"><strong>{state.correct_count} / {state.total}</strong><span>Correct</span></div>
          <div className="result-card"><strong>{state.accuracy}%</strong><span>Accuracy</span></div>
          <div className="result-card"><strong>{state.best_streak}</strong><span>Longest streak</span></div>
        </div>
        <div className="room-actions">
          <button className="button button-primary" onClick={playAgain}>Play again</button>
          <button className="button button-quiet" onClick={onBack}>Back to home</button>
        </div>
        <div className="section-heading"><h2>Answer review</h2></div>
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
      </section>
    );
  }

  // ---------- A question: answering or reveal ----------
  const question: SoloQuestionState = state;
  const revealed = question.phase === 'reveal';
  const selected = question.selected_answer ?? pendingAnswer;
  const remaining = Math.max(0, deadline - Date.now());
  const secondsLeft = Math.ceil(remaining / 1000);

  return (
    <section className="subpage narrow-view">
      <div className="solo-hud">
        <span>Question {question.position} / {question.total}</span>
        <span className={`difficulty-pill diff-${question.difficulty}`}>{question.difficulty}</span>
        <span>Score <b>{question.score}</b></span>
        <span>Streak <b>{question.streak}</b></span>
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
        {question.options.map((option) => {
          let stateClass = '';
          if (revealed) {
            if (option === question.correct_answer) stateClass = 'is-correct';
            else if (option === question.selected_answer) stateClass = 'is-wrong';
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
              onClick={() => void choose(option)}
            >
              {option}
            </button>
          );
        })}
      </div>

      {!revealed && selected && <p className="vote-help">Answer locked. The result is revealed when the timer ends.</p>}

      {revealed && (
        <div className={`reveal-box ${question.is_correct ? 'is-correct' : 'is-wrong'}`}>
          <strong>
            {question.is_correct ? 'Correct!' : question.selected_answer ? 'Not quite.' : 'Time ran out.'}{' '}
            {pointsText(question.points_awarded ?? 0, question.selected_answer !== null)}
          </strong>
          {!question.is_correct && <p>The correct answer was <b>{question.correct_answer}</b>.</p>}
          <p>{question.explanation}</p>
          {question.source_url && (
            <a className="source-link" href={question.source_url} target="_blank" rel="noopener noreferrer">Source: {question.source_title}</a>
          )}
          <button className="button button-primary" disabled={busy} onClick={() => void next()}>
            {question.is_last ? 'See results' : 'Next question'}
          </button>
        </div>
      )}
    </section>
  );
}
