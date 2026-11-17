export function pickAccessoryIndex(matches: boolean[]): number {
  for (let i = 0; i < matches.length; i++) {
    if (matches[i]) {
      return i;
    }
  }
  return matches.length === 1 ? 0 : -1;
}