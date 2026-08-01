import { escapeCsvField, toCsv } from "../utils/csvExport";

describe("escapeCsvField", () => {
  test("plain value passes through unquoted", () => {
    expect(escapeCsvField("Deck repair")).toBe("Deck repair");
  });

  test("empty string passes through", () => {
    expect(escapeCsvField("")).toBe("");
  });

  test("comma triggers quoting", () => {
    expect(escapeCsvField("Smith, Jones & Co")).toBe('"Smith, Jones & Co"');
  });

  test("embedded quotes are doubled and the field quoted", () => {
    expect(escapeCsvField('the "big" job')).toBe('"the ""big"" job"');
  });

  test("newline triggers quoting", () => {
    expect(escapeCsvField("line one\nline two")).toBe('"line one\nline two"');
  });

  test("carriage return triggers quoting", () => {
    expect(escapeCsvField("a\rb")).toBe('"a\rb"');
  });

  test("accented characters pass through untouched", () => {
    expect(escapeCsvField("José Núñez")).toBe("José Núñez");
  });
});

describe("toCsv", () => {
  test("header only when there are no rows, with trailing CRLF", () => {
    expect(toCsv(["A", "B"], [])).toBe("A,B\r\n");
  });

  test("joins fields with commas and lines with CRLF", () => {
    expect(toCsv(["A", "B"], [["1", "2"], ["3", "4"]])).toBe(
      "A,B\r\n1,2\r\n3,4\r\n"
    );
  });

  test("escapes every field including headers", () => {
    expect(toCsv(["Name, full"], [['say "hi"']])).toBe(
      '"Name, full"\r\n"say ""hi"""\r\n'
    );
  });
});
