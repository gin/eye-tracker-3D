export interface LeaderboardEntry {
  score: number;
  at: number;
}

const LEADERBOARD_STORAGE_KEY = "eye3d.leaderboard.v1";
const MAX_ENTRIES = 10;

function isLeaderboardEntry(value: unknown): value is LeaderboardEntry {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Record<string, unknown>;
  return typeof candidate.score === "number" && typeof candidate.at === "number";
}

export function loadLeaderboard(): LeaderboardEntry[] {
  try {
    const raw = localStorage.getItem(LEADERBOARD_STORAGE_KEY);
    if (!raw) return [];
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    // Ties keep their relative input order (Array.prototype.sort is stable),
    // so an older entry outranks a newly-recorded one with the same score.
    return parsed.filter(isLeaderboardEntry).sort((a, b) => b.score - a.score);
  } catch {
    // Private-browsing storage lockouts and corrupted JSON both just mean
    // "no saved scores" — falling back to an empty leaderboard is fine.
    return [];
  }
}

export function recordScore(score: number): { entries: LeaderboardEntry[]; rank: number } {
  const entry: LeaderboardEntry = { score, at: Date.now() };
  // Appending the new entry last, before the stable sort, is what makes ties
  // resolve in favor of existing, older entries.
  const merged = [...loadLeaderboard(), entry].sort((a, b) => b.score - a.score);
  const entries = merged.slice(0, MAX_ENTRIES);
  const foundIndex = entries.indexOf(entry); // reference equality picks out THIS entry, not just a matching score
  const rank = foundIndex === -1 ? -1 : foundIndex + 1;

  try {
    localStorage.setItem(LEADERBOARD_STORAGE_KEY, JSON.stringify(entries));
  } catch {
    // Private-browsing storage lockouts mean the score can't be persisted;
    // still report the rank the player earned this session.
  }

  return { entries, rank };
}
