/**
 * Smoke tests for the UI component library.
 * RNTL v14 ships an async render() — every test must await it.
 */
import React from "react";
import { render } from "@testing-library/react-native";
import { Badge, Button, EmptyState, SectionHeader, StatCard } from "../components/UI";

describe("Badge", () => {
  it("renders its label text", async () => {
    const { getByText } = await render(<Badge label="7d overdue" color="danger" />);
    expect(getByText("7d overdue")).toBeTruthy();
  });

  it("renders with default color prop without crashing", async () => {
    const { getByText } = await render(<Badge label="Paid" />);
    expect(getByText("Paid")).toBeTruthy();
  });
});

describe("Button", () => {
  it("renders its label text", async () => {
    const { getByText } = await render(<Button label="Save" onPress={() => {}} />);
    expect(getByText("Save")).toBeTruthy();
  });

  it("renders ghost variant without crashing", async () => {
    const { getByText } = await render(
      <Button label="Cancel" variant="ghost" onPress={() => {}} />
    );
    expect(getByText("Cancel")).toBeTruthy();
  });

  it("hides label and shows spinner when loading", async () => {
    const { queryByText } = await render(<Button label="Save" onPress={() => {}} loading />);
    expect(queryByText("Save")).toBeNull();
  });
});

describe("EmptyState", () => {
  it("renders its message text", async () => {
    const { getByText } = await render(
      <EmptyState message="No jobs yet. Add your first job to get started." />
    );
    expect(getByText("No jobs yet. Add your first job to get started.")).toBeTruthy();
  });
});

describe("SectionHeader", () => {
  it("renders its title text", async () => {
    const { getByText } = await render(<SectionHeader title="Recent Jobs" />);
    expect(getByText("Recent Jobs")).toBeTruthy();
  });
});

describe("StatCard", () => {
  it("renders both label and value", async () => {
    const { getByText } = await render(
      <StatCard label="Total revenue" value="$4,200" />
    );
    expect(getByText("Total revenue")).toBeTruthy();
    expect(getByText("$4,200")).toBeTruthy();
  });
});
