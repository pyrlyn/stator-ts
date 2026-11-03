interface Parts {
  dir?: string;
}

export function strict(p: Parts): string {
  const dir = p.dir !== undefined ? p.dir : 'r';
  return dir;
}

export function chained(p: Parts): string {
  if (p.dir !== undefined && p.dir !== '') {
    return p.dir;
  }
  return 'r';
}

export function equal(p: Parts): string {
  return p.dir === undefined ? 'r' : p.dir;
}

export function absent(p: Parts): undefined {
  if (p.dir === undefined) {
    return p.dir;
  }
  return undefined;
}
