export type SportCategory = {
  slug: string;
  sport: string;
  label: string;
};

// The 14 categories frozen for SportStack v1.1. Questions will be added in Phase 3.
export const launchCategories: SportCategory[] = [
  { slug: 'football-premier-league', sport: 'Football', label: 'Premier League' },
  { slug: 'football-champions-league', sport: 'Football', label: 'Champions League' },
  { slug: 'cricket-international', sport: 'Cricket', label: 'International Cricket' },
  { slug: 'cricket-ipl', sport: 'Cricket', label: 'IPL' },
  { slug: 'tennis-grand-slams', sport: 'Tennis', label: 'Grand Slam Tournaments' },
  { slug: 'tennis-general', sport: 'Tennis', label: 'General Tennis' },
  { slug: 'f1-drivers-champions', sport: 'Formula 1', label: 'Drivers & Champions' },
  { slug: 'f1-teams-constructors', sport: 'Formula 1', label: 'Teams & Constructors' },
  { slug: 'motogp-riders-champions', sport: 'MotoGP', label: 'Riders & Champions' },
  { slug: 'motogp-circuits-grands-prix', sport: 'MotoGP', label: 'Circuits & Grands Prix' },
  { slug: 'basketball-nba', sport: 'Basketball', label: 'NBA' },
  { slug: 'basketball-fiba', sport: 'Basketball', label: 'International/FIBA Basketball' },
  { slug: 'olympics-history-records', sport: 'Olympics & Other Sports', label: 'Olympic History & Records' },
  { slug: 'other-sports-rules-history', sport: 'Olympics & Other Sports', label: 'Other Sports: Rules & History' },
];
