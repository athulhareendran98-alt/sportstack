# SportStack — Phase 1 foundation

SportStack is a competitive sports quiz for curious fans. This repository is the first implementation phase: secure guest identity, public waiting rooms, room creation/joining, readiness state, private Realtime room notifications, refresh recovery, and the database/server foundation.

The Solo Challenge and the actual quiz engine are planned for later phases. The home screen shows them as planned features; Phase 1 intentionally does not pretend a match can start before category voting and category consensus are implemented.

## Tech stack

- React + TypeScript + Vite for the responsive website
- Supabase Anonymous Auth for account-free guest identity
- Supabase PostgreSQL for rooms, players, categories, questions and match records
- Supabase Edge Function `game-api` for trusted room actions
- Supabase Realtime Broadcast over private room channels
- GitHub Pages for the eventual static frontend URL

## Phase 1 features included

- Premium dark navy / neon green / white visual system
- Guest name input and persistent anonymous session
- Create public waiting rooms with a six-character code
- List open rooms and join by room code
- Room player list, host marker and ready/not-ready state
- Private Realtime room updates plus an 8-second polling fallback
- Refresh recovery in the same tab and a rejoin prompt in a new browser tab
- Server-side room capacity checks, serialized joins, unique player tags, host transfer after an inactive host, and cleanup of stale empty rooms
- RLS enabled on all application tables; clients use the Edge Function instead of direct table access
- Schema ready for the 14 launch categories, curated question bank, matches, answers and question reports

## What is not implemented yet

The following are deliberately left for later roadmap phases: category voting UI and shared-category consensus; automatic countdown and the match engine; the 210 verified questions; question timer, scoring and streaks; Solo Challenge gameplay; results/review/rematch; report-player UI and rate limiting; and final release testing. The room screen cannot start a match in Phase 1.

## Setup guide (when you're ready to connect services)

### 1. Install Node.js

Install a current Node.js LTS release from https://nodejs.org/. Then open a terminal in this project folder.

### 2. Install dependencies and preview the app

```bash
npm install
cp .env.example .env.local
npm run dev
```

On Windows PowerShell, use `Copy-Item .env.example .env.local` instead of `cp`.

The site can render without credentials, but online actions require Supabase to be configured.

### 3. Create the Supabase project

1. Create a project at https://supabase.com/.
2. In the Supabase dashboard, enable **Anonymous sign-ins** in Authentication settings. The UI wording may vary slightly.
3. Find your Project URL and publishable key in the project's API/Connect settings.
4. Put them in `.env.local`:

```dotenv
VITE_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=sb_publishable_your_public_key
VITE_BASE_PATH=/
```

The publishable key is intended for the browser. **Never put a Supabase secret/service-role key in `VITE_*`, frontend code, or a public GitHub repository.**

### 4. Apply the database migration

Install the Supabase CLI using the official guide: https://supabase.com/docs/guides/cli. Sign in, link the project, then run the migration:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

This applies `supabase/migrations/202610030001_sportstack_foundation.sql`. It creates the launch-category catalogue and the core schema, enables RLS, and installs server-only RPC functions and private room broadcast policies.

### 5. Deploy the Edge Function

The function needs a server-side secret key. Use the Supabase secret key for server-side operations, or the legacy service-role key where that is what your project provides. Never share the value or commit it to GitHub.

```bash
supabase secrets set SUPABASE_SECRET_KEY=YOUR_SERVER_SECRET_KEY
supabase functions deploy game-api
```

Supabase provides `SUPABASE_URL`; the function accepts `SUPABASE_SECRET_KEY` or `SUPABASE_SERVICE_ROLE_KEY`, and `SUPABASE_PUBLISHABLE_KEY` or `SUPABASE_ANON_KEY` for caller-token verification. If your project doesn't provide `SUPABASE_PUBLISHABLE_KEY` to functions by default, set it as a function secret as well:

```bash
supabase secrets set SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

The function has JWT verification enabled. The browser must have a valid Supabase anonymous-auth session before it can use room actions.

### 6. Test Phase 1 locally

Restart `npm run dev` after editing `.env.local`.

1. Open the local site and enter a display name.
2. Choose **Multiplayer** and create a room.
3. Open the same local site in another browser or on another device, use a different guest session, and join with the room code.
4. Toggle **I'm ready** on each device. The player list and ready state should update on both devices.
5. Refresh one tab. It should reconnect to the active room.
6. Try creating a room and leaving as host. The waiting room should close for its members.

For a true separate-device test, both devices must be able to reach the same deployed frontend and Supabase project. Localhost on one device is not automatically accessible from another device.

## Security model

- The browser only receives the project URL and publishable key. These are not server secrets.
- Room mutations go through `game-api`, which validates the caller's Supabase access token and takes the user's ID from that verified token rather than trusting a user ID sent in the request body.
- Tables have RLS enabled and no client-facing read/write policies for application data. The Edge Function uses its server key to call restricted RPC functions.
- Realtime topics are private and readable only to active room members. Broadcast payloads contain a minimal room-change notification, not answer keys or full player records.
- This is still Phase 1. Rate limits, production abuse controls, complete match authorization, privacy review and full security testing remain required before a public competitive launch.

## Known Phase 1 boundaries

The public lobby is polling every five seconds. Room state uses private Broadcast notifications plus a polling fallback. Category votes are represented in the database but not yet exposed in the UI. The waiting-room UI cannot start a match until Phase 2 implements category voting and the agreed rule that every player must share at least one category.

## GitHub Pages deployment (later, after testing)

A workflow is included at `.github/workflows/deploy.yml`. Before using it, add repository Actions variables:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY`

The workflow sets the Vite base path to `/<repository-name>/`, builds the app, and deploys the static frontend. Enable **Settings → Pages → Build and deployment → GitHub Actions** in the repository. Deploy the Supabase migration and Edge Function separately; GitHub Pages only hosts the frontend.
