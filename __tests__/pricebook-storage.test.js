import AsyncStorage from "@react-native-async-storage/async-storage";
import { loadPricebook, savePricebook } from "../utils/storage";

jest.mock("../utils/sync", () => ({
  enqueue: jest.fn(),
  enqueueCollectionChanges: jest.fn(),
  trySync: jest.fn(),
}));

jest.mock("../utils/notifications", () => ({
  syncNotifications: jest.fn(),
}));

const { enqueueCollectionChanges, trySync } = require("../utils/sync");

beforeEach(() => {
  jest.clearAllMocks();
  AsyncStorage.getItem.mockResolvedValue(null);
  AsyncStorage.setItem.mockResolvedValue(undefined);
});

describe("Pricebook storage", () => {
  const entry = {
    id: "pb-1",
    name: "Water Heater Install",
    description: "Standard 40-gal tank replacement",
    category: "Plumbing",
    laborHours: 4,
    laborRate: 95,
    materials: [{ id: "m1", name: "40-gal tank", quantity: 1, unitCost: 450 }],
    materialMarkup: 20,
    overhead: 15,
    margin: 20,
    estimateTotal: 1200,
    createdAt: "2026-07-08T00:00:00.000Z",
    updatedAt: "2026-07-08T00:00:00.000Z",
  };

  test("loadPricebook returns [] when cache is empty", async () => {
    const result = await loadPricebook();
    expect(result).toEqual([]);
  });

  test("loadPricebook returns parsed entries", async () => {
    AsyncStorage.getItem.mockResolvedValue(JSON.stringify([entry]));
    const result = await loadPricebook();
    expect(result).toHaveLength(1);
    expect(result[0].name).toBe("Water Heater Install");
  });

  test("savePricebook persists, enqueues changes, and triggers sync", async () => {
    await savePricebook([entry]);
    expect(AsyncStorage.setItem).toHaveBeenCalledWith(
      "pricebook",
      JSON.stringify([entry])
    );
    expect(enqueueCollectionChanges).toHaveBeenCalledWith(
      "pricebook",
      [],
      [entry]
    );
    expect(trySync).toHaveBeenCalled();
  });
});
