/**
 * Who waits for a PR's Ask chat to change. In the ask queue's object, where every question arrives and every turn runs:
 * a held `GET …/ask` waits here instead of the phone reading every 2 seconds. Memory only: a new object's versions match
 * no one's, so whoever waits reads again.
 */
export class AskChanges {
  private readonly born: number;
  private version: number;
  private readonly versions = new Map<string, number>();
  private readonly waiting = new Map<string, Set<() => void>>();
  private readonly activities = new Map<string, string>();

  constructor(now = Date.now()) {
    this.version = now;
    this.born = now;
  }

  /** Read before the chat is, so a change between the two ends the wait at once. */
  now(pr: string): { version: number; activity: string | null } {
    return {
      version: this.versions.get(pr) ?? this.born,
      activity: this.activities.get(pr) ?? null,
    };
  }

  /** What the agent is doing on the turn running now; null once it has ended. */
  doing(pr: string, activity: string | null): void {
    if (activity === null) {
      this.activities.delete(pr);
    } else {
      this.activities.set(pr, activity);
    }
    this.changed(pr);
  }

  changed(pr: string): void {
    this.versions.set(pr, ++this.version);
    const waiting = this.waiting.get(pr);
    this.waiting.delete(pr);
    for (const wake of waiting ?? []) {
      wake();
    }
  }

  /** Until the chat is at another version than `seen`, or `ms` have passed. */
  async wait(pr: string, seen: number, ms: number): Promise<void> {
    if (this.now(pr).version !== seen) {
      return;
    }
    await new Promise<void>((resolve) => {
      const waiting = this.waiting.get(pr) ?? new Set();
      this.waiting.set(pr, waiting);
      const timer = setTimeout(() => {
        waiting.delete(wake);
        resolve();
      }, ms);
      const wake = () => {
        clearTimeout(timer);
        resolve();
      };
      waiting.add(wake);
    });
  }
}
