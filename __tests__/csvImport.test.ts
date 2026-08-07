// __tests__/csvImport.test.ts
import { parseCsv, hashCsv } from "../utils/csvImport";

describe("parseCsv", () => {
  test("splits a simple comma file into headers + rows", () => {
    const out = parseCsv("Name,Phone\nAda,555-1\nGrace,555-2\n");
    expect(out.headers).toEqual(["Name", "Phone"]);
    expect(out.rows).toEqual([["Ada", "555-1"], ["Grace", "555-2"]]);
    expect(out.rowCount).toBe(2);
    expect(out.truncated).toBe(false);
  });

  test("honours quoted fields with commas, newlines, and escaped quotes", () => {
    const text = 'Name,Notes\n"Smith, Bob","line1\nline2"\n"She said ""hi""",ok\n';
    const out = parseCsv(text);
    expect(out.rows[0]).toEqual(["Smith, Bob", "line1\nline2"]);
    expect(out.rows[1]).toEqual(['She said "hi"', "ok"]);
  });

  test("strips a UTF-8 BOM and handles CRLF line endings", () => {
    const out = parseCsv("﻿Name,Phone\r\nAda,555\r\n");
    expect(out.headers).toEqual(["Name", "Phone"]);
    expect(out.rows).toEqual([["Ada", "555"]]);
  });

  test("pads short rows and ignores a trailing blank line", () => {
    const out = parseCsv("A,B,C\n1,2\n\n");
    expect(out.rows).toEqual([["1", "2", ""]]);
  });

  test("never throws on malformed input; returns empty on empty text", () => {
    expect(parseCsv("").headers).toEqual([]);
    expect(() => parseCsv('"unterminated,quote\nrow')).not.toThrow();
  });

  test("soft row cap truncates and flags", () => {
    const body = Array.from({ length: 10 }, (_, i) => `r${i}`).join("\n");
    const out = parseCsv(`H\n${body}\n`, { maxRows: 4 });
    expect(out.rows).toHaveLength(4);
    expect(out.truncated).toBe(true);
  });
});

describe("hashCsv", () => {
  test("is stable and differs for different content", () => {
    expect(hashCsv("A,B\n1,2\n")).toBe(hashCsv("A,B\n1,2\n"));
    expect(hashCsv("A,B\n1,2\n")).not.toBe(hashCsv("A,B\n1,3\n"));
  });
});
