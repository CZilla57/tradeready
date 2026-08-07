// __tests__/jobPhotoVisibilityToggle.test.tsx
// Phase 12B: the per-photo "visible to customer" toggle on JobDetail's
// PhotosCard (exported for this test). Absent customerVisible means HIDDEN —
// the badge must read as hidden for both absent and false, and the toggle
// callback carries the photo id. Storage semantics are pinned separately in
// jobPhotosStorage.test.ts (setJobPhotoVisibility).
//
// No ThemeProvider wrapper (ThemeContext default value — changeOrdersSection
// convention). RNTL v14: await render, await every fireEvent.

import React from "react";
import { render, fireEvent, act } from "@testing-library/react-native";
import { PhotosCard } from "../screens/JobDetailScreen";
import type { JobPhoto } from "../types/models";

const hidden: JobPhoto = {
  id: "p1_hidden",
  jobId: "j1",
  createdAt: "2026-08-08T10:00:00.000Z",
  uploadedAt: "2026-08-08T10:00:03.000Z",
};

const visible: JobPhoto = {
  id: "p2_visible",
  jobId: "j1",
  createdAt: "2026-08-08T10:01:00.000Z",
  uploadedAt: "2026-08-08T10:01:03.000Z",
  customerVisible: true,
};

async function renderCard(onToggleVisible = jest.fn()) {
  const utils = await render(
    <PhotosCard
      photos={[hidden, visible]}
      readyIds={new Set<string>()}
      onAdd={jest.fn()}
      onDelete={jest.fn()}
      onToggleVisible={onToggleVisible}
    />,
  );
  return { ...utils, onToggleVisible };
}

describe("PhotosCard visibility toggle", () => {
  test("absent flag renders as hidden; explicit true renders as visible", async () => {
    const { getByLabelText } = await renderCard();
    expect(getByLabelText("Hidden from customer — tap to show on portal")).toBeTruthy();
    expect(getByLabelText("Visible to customer — tap to hide")).toBeTruthy();
  });

  test("pressing the badge reports the photo id", async () => {
    const { getByLabelText, onToggleVisible } = await renderCard();
    await act(async () => {
      fireEvent.press(getByLabelText("Hidden from customer — tap to show on portal"));
    });
    expect(onToggleVisible).toHaveBeenCalledWith("p1_hidden");
    await act(async () => {
      fireEvent.press(getByLabelText("Visible to customer — tap to hide"));
    });
    expect(onToggleVisible).toHaveBeenCalledWith("p2_visible");
  });
});
