class Uri {
  readonly path = '/';
  // A key computed by a call is never a known member, so the class stays closed.
  [Symbol.for('debug.description')]() {
    return this.path;
  }
}

// The awaited value must stay a Uri: a class open to any member would look like a thenable.
export async function roots(all: Promise<Uri>[]) {
  const list = await Promise.all(all);
  return list.map(root => root.path);
}

// error: the class has no such property.
export const wrong: { missing: number } = new Uri();
