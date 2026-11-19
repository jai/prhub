// An R2 bucket in memory, for code that takes the `DIFFS` binding or a slice of it: what it holds, and every put in order.

/** An object as a test seeds it. */
export interface Held {
  body: string;
  customMetadata?: Record<string, string>;
  uploaded?: Date;
}

export interface Put {
  key: string;
  value: string;
  customMetadata: Record<string, string> | undefined;
}

const text = (value: string | ArrayBuffer | ArrayBufferView) =>
  typeof value === "string" ? value : new TextDecoder().decode(value);

/** `held` seeds the bucket; `pageSize` is how many keys one `list` answers at most, so paging runs. */
export function memoryR2(held: Record<string, Held> = {}, { pageSize = 1_000 } = {}) {
  const objects = new Map<string, Required<Held>>(
    Object.entries(held).map(([key, one]) => [
      key,
      {
        body: one.body,
        customMetadata: one.customMetadata ?? {},
        uploaded: one.uploaded ?? new Date(0),
      },
    ]),
  );
  const puts: Put[] = [];
  const meta = (key: string) => {
    const one = objects.get(key);
    return one ? { key, customMetadata: one.customMetadata, uploaded: one.uploaded } : null;
  };
  const bucket = {
    objects,
    puts,
    /** What `key` holds now, read without awaiting; undefined when nothing is there. */
    bodyOf(key: string): string | undefined {
      return objects.get(key)?.body;
    },
    async head(key: string) {
      return meta(key);
    },
    async get(key: string) {
      const one = objects.get(key);
      return one
        ? {
            ...meta(key),
            body: one.body,
            text: async () => one.body,
            json: async <T>() => JSON.parse(one.body) as T,
          }
        : null;
    },
    async put(
      key: string,
      value: string | ArrayBuffer | ArrayBufferView,
      options?: { customMetadata?: Record<string, string> },
    ) {
      const body = text(value);
      puts.push({ key, value: body, customMetadata: options?.customMetadata });
      objects.set(key, {
        body,
        customMetadata: options?.customMetadata ?? {},
        uploaded: new Date(0),
      });
      return meta(key);
    },
    async delete(keys: string | string[]) {
      for (const key of [keys].flat()) {
        objects.delete(key);
      }
    },
    async list({ prefix = "", cursor }: { prefix?: string; cursor?: string; limit?: number } = {}) {
      const keys = [...objects.keys()].filter((key) => key.startsWith(prefix)).sort();
      const start = cursor ? Number(cursor) : 0;
      const page = keys.slice(start, start + pageSize);
      const truncated = start + pageSize < keys.length;
      return {
        objects: page.map((key) => meta(key)!),
        truncated,
        cursor: truncated ? String(start + pageSize) : undefined,
      };
    },
  };
  /** The same bucket typed as the binding, for code that takes an `R2Bucket`. */
  return Object.assign(bucket, { binding: bucket as unknown as R2Bucket });
}

export type MemoryR2 = ReturnType<typeof memoryR2>;
