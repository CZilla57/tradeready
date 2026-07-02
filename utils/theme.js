// utils/theme.js
// All colors, spacing, and font sizes in one place.
// Change something here and it updates everywhere in the app.

export const colors = {
  // Backgrounds
  background: "#f2f2f7",       // iOS system grouped background
  surface: "#ffffff",           // Card / sheet background
  surfaceSecondary: "#f2f2f7",

  // Text
  textPrimary: "#000000",
  textSecondary: "#6c6c70",
  textMuted: "#aeaeb2",
  textOnAccent: "#ffffff",

  // Brand / accent
  accent: "#007aff",            // iOS blue

  // Semantic
  danger: "#ff3b30",            // iOS red
  warning: "#ff9500",           // iOS orange
  success: "#34c759",           // iOS green
  dangerBg: "#fff1f0",
  warningBg: "#fff8ed",
  successBg: "#f0faf3",
  accentBg: "#f0f6ff",

  // Borders
  border: "#e5e5ea",
  borderStrong: "#c7c7cc",

  // Job pipeline status colors
  // Used by TodayScreen, JobsScreen, and any future screen that renders job status badges.
  // Defined here so all screens stay in sync if we ever rebrand or add dark mode.
  statusScheduled:  "#3B82F6", // blue
  statusInProgress: "#F59E0B", // amber
  statusComplete:   "#10B981", // green
  statusEstimate:   "#8B5CF6", // purple
  statusLead:       "#6B7280", // grey
  statusInvoiced:   "#06B6D4", // cyan
  statusPaid:       "#34C759", // same as success
};

export const spacing = {
  xs: 4,
  sm: 8,
  md: 16,
  lg: 24,
  xl: 32,
};

export const radius = {
  sm: 8,
  md: 12,
  lg: 16,
  full: 999,
};

export const fontSize = {
  xs: 11,
  sm: 13,
  md: 15,
  lg: 17,
  xl: 22,
  xxl: 28,
};

export const shadow = {
  card: {
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.06,
    shadowRadius: 4,
    elevation: 2,
  },
};
