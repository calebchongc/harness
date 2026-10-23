import { describe, expect, it } from "vitest";
import { type DocMessagePart, fromDocParts, toDocParts, splitMessageEntry, joinContinuations } from "./messages";
import { toRenderParts } from "./render-parts";

describe("native visual parts", () => {
  const visual = { kind: "visual" as const, id: "v", title: "Overview", script: "return function() return ui.text('Hello') end" };

  it("round-trips mixed parts as atomic source without leaking into prose", () => {
    const parts = [{ kind: "text" as const, id: "before", text: "Before" }, visual,
      { kind: "text" as const, id: "after", text: "After" }];
    const doc = toDocParts(toRenderParts(parts));
    expect(doc).toEqual(parts);
    expect(doc[1]).not.toHaveProperty("text");
    expect(doc[1]).not.toHaveProperty("reasoning");
    expect(fromDocParts(doc)).toEqual(parts);
    const entry = { id: "a", role: "assistant" as const, deviceId: "owner", createdAt: 1, parts: doc };
    const split = splitMessageEntry(entry, 80);
    expect(split).toHaveLength(3);
    expect(split[1]!.parts).toEqual([visual]);
    expect(joinContinuations(split)).toEqual([entry]);
  });

  it("bounds title code points and script UTF-8 bytes in both directions", () => {
    for (const title of ["界".repeat(200), "😀".repeat(200), "e\u0301".repeat(100)]) {
      const part = { ...visual, title, script: "é".repeat(32768) };
      expect(fromDocParts(toDocParts([part]))).toEqual([part]);
    }
    for (const fields of [
      { title: undefined }, { title: 42 }, { title: " \n\t" },
      { title: "界".repeat(201) }, { title: "e\u0301".repeat(101) },
      { script: undefined }, { script: 42 }, { script: " \n\t" },
      { script: "é".repeat(32769) }
    ]) {
      const bad = { ...visual, ...fields, text: "must not leak", reasoning: "must not leak" };
      const fallback = [{ kind: "text", id: "v", text: "" }];
      expect(toDocParts([bad as unknown as typeof visual])).toEqual(fallback);
      expect(fromDocParts([bad as unknown as DocMessagePart])).toEqual(fallback);
    }
  });
});

describe("generated image parts", () => {
  const image = { kind: "image" as const, id: "i:image", path: "/uploads/generated.png", name: "generated.png", mimeType: "image/png" };
  it("preserves only the structured reference through render/doc conversion", () => {
    expect(fromDocParts(toDocParts(toRenderParts([image])))).toEqual([image]);
  });
  it("keeps images atomic through split/join", () => {
    const entry = { id: "a", role: "assistant" as const, deviceId: "owner", createdAt: 1, parts: [image, { ...image, id: "j:image" }] };
    const split = splitMessageEntry(entry, 160);
    expect(split).toHaveLength(2);
    expect(joinContinuations(split)).toEqual([entry]);
  });
  it("degrades malformed references without rendering paths as text", () => {
    for (const part of [{ kind: "image" as const, id: "i" }, { ...image, mimeType: "image/svg+xml" }, { ...image, path: 42 } as unknown as DocMessagePart]) {
      expect(fromDocParts([part])).toEqual([{ kind: "error", id: part.id, message: "Generated image unavailable" }]);
    }
  });
});
