export class NotchFold {
  hovered = false;
  private timer?: ReturnType<typeof setTimeout>;
  constructor(readonly blocked: () => boolean, readonly fold: () => void) {}
  changed() {
    this.cancel();
    if (!this.hovered && !this.blocked()) this.timer = setTimeout(() => {
      this.timer = undefined;
      if (!this.hovered && !this.blocked()) this.fold();
    }, 450);
  }
  cancel() { if (this.timer) clearTimeout(this.timer); this.timer = undefined; }
}
