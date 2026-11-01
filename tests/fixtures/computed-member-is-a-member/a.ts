// A computed member is one more member once its name is known, not a sign that anything goes.
declare const marker: unique symbol;
const named = "named";

interface Config {
  name?: string;
  [marker]?: true;
  [named]?: number;
}

interface Profile {
  profileName: string;
  name?: string;
}

declare const config: Config;

export const missing: { profileName: string } = config;
export const fine: { name?: string } = config;
export const byMarker: { [marker]?: true } = config;
export const byName: { named?: number } = config;
export const wrong: { named?: string } = config;

type FilterType<T, U> = T extends U ? T : never;

export function narrow(x: Config | Profile) {
  const picked: FilterType<Config | Profile, { profileName: unknown }> = x as Profile;
  return picked.profileName;
}

export const dropped: FilterType<Config, { profileName: unknown }> = config;
