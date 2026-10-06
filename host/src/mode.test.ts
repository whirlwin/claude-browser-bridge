import { describe, expect, it } from "vitest";
import { parseMode } from "./mode";

describe("parseMode", () => {
  it("accepts the known modes", () => {
    expect(parseMode(["host"])).toBe("host");
    expect(parseMode(["mcp"])).toBe("mcp");
  });

  it("ignores the extra arguments Chrome appends", () => {
    expect(parseMode(["host", "chrome-extension://abc/"])).toBe("host");
  });

  it("rejects missing or unknown modes", () => {
    expect(parseMode([])).toBeUndefined();
    expect(parseMode(["serve"])).toBeUndefined();
  });
});
