export const lightColors = {
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
  statusLead:       "#6B7280",
  statusEstimate:   "#8B5CF6",
  statusApproved:   "#14B8A6",
  statusScheduled:  "#3B82F6",
  statusInProgress: "#F59E0B",
  statusComplete:   "#10B981",
  statusInvoiced:   "#06B6D4",
  statusPaid:       "#34C759",
};

export const darkColors = {
  // Backgrounds
  background: "#000000",        // iOS true black (OLED-friendly)
  surface: "#1c1c1e",           // iOS dark secondary grouped background
  surfaceSecondary: "#000000",

  // Text
  textPrimary: "#ffffff",
  textSecondary: "#aeaeb2",     // iOS dark secondary label
  textMuted: "#636366",         // iOS dark tertiary label
  textOnAccent: "#ffffff",

  // Brand / accent
  accent: "#0a84ff",            // iOS blue dark

  // Semantic
  danger: "#ff453a",            // iOS red dark
  warning: "#ff9f0a",           // iOS orange dark
  success: "#30d158",           // iOS green dark
  dangerBg: "#2d0f0f",
  warningBg: "#2d1f00",
  successBg: "#0a2a15",
  accentBg: "#001830",

  // Borders
  border: "#38383a",
  borderStrong: "#48484a",

  // Job pipeline status colors (brighter for dark backgrounds)
  statusLead:       "#8D95A0",
  statusEstimate:   "#a78bfa",
  statusApproved:   "#2dd4bf",
  statusScheduled:  "#60a5fa",
  statusInProgress: "#fbbf24",
  statusComplete:   "#34d399",
  statusInvoiced:   "#22d3ee",
  statusPaid:       "#30d158",
};

export type ColorScheme = typeof lightColors;

// Keep `colors` as the light palette for any legacy static usage (ErrorBoundary, etc.)
export const colors = lightColors;

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

export const darkShadow = {
  card: {
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.4,
    shadowRadius: 8,
    elevation: 5,
  },
};

export type ShadowScheme = typeof shadow;
