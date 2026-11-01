interface Part {
  label: string;
  tooltip?: string;
  command?: { id: string };
}

declare const parts: Part[];

class Rendered {
  constructor(readonly label: string | Part[], readonly index: number) {}

  // The declared interface survives: it says more than the literal next to it.
  get part() {
    const label = this.label;
    if (typeof label === 'string') {
      return { label };
    }
    return label[this.index];
  }
}

export const command = new Rendered(parts, 0).part.command;

// error: the union still holds no such property.
export const wrong = new Rendered(parts, 0).part.missing;
