export const lightColors = {
  // Backgrounds
  background: "#f5f5f1",       // vellum — cool-warm paper, not iOS gray
  surface: "#ffffff",           // Card / sheet background
  surfaceSecondary: "#f5f5f1",

  // Text
  textPrimary: "#14213d",       // ink — deep blueprint navy
  textSecondary: "#4b5568",
  textMuted: "#8b93a3",
  textOnAccent: "#ffffff",

  // Brand / accent
  accent: "#1d5c9e",             // blueprint blue

  // Semantic
  danger: "#b8432b",             // rust
  warning: "#c97f1d",            // hazard amber
  success: "#2e8b67",            // patina green
  dangerBg: "#fbe9e4",
  warningBg: "#fbeedd",
  successBg: "#e4f3ec",
  accentBg: "#e4eef7",

  // Borders
  border: "#dedfd8",
  borderStrong: "#c7c9be",

  // Job pipeline status colors
  statusLead:       "#6B7280",
  statusEstimate:   "#8B5CF6",
  statusApproved:   "#14B8A6",
  statusScheduled:  "#3B82F6",
  statusInProgress: "#F59E0B",
  statusComplete:   "#10B981",
  statusInvoiced:   "#06B6D4",
  statusPaid:       "#34C759",
  statusDeclined:   "#EF4444",   // red — declined estimate
};

export const darkColors = {
  // Backgrounds
  background: "#101826",        // deep blueprint-ink — not pure OLED black
  surface: "#182238",
  surfaceSecondary: "#101826",

  // Text
  textPrimary: "#f2f4f8",
  textSecondary: "#aeb6c6",
  textMuted: "#6e7789",
  textOnAccent: "#ffffff",

  // Brand / accent
  accent: "#5b9bdb",             // blueprint blue, brightened for dark ground

  // Semantic
  danger: "#e06a4f",             // rust, brightened
  warning: "#e4a039",            // hazard amber, brightened
  success: "#4fbf93",            // patina, brightened
  dangerBg: "#3a1712",
  warningBg: "#3a2a10",
  successBg: "#123326",
  accentBg: "#1b2c40",

  // Borders
  border: "#263248",
  borderStrong: "#34405a",

  // Job pipeline status colors (brighter for dark backgrounds)
  statusLead:       "#8D95A0",
  statusEstimate:   "#a78bfa",
  statusApproved:   "#2dd4bf",
  statusScheduled:  "#60a5fa",
  statusInProgress: "#fbbf24",
  statusComplete:   "#34d399",
  statusInvoiced:   "#22d3ee",
  statusPaid:       "#30d158",
  statusDeclined:   "#f87171",   // red — declined estimate (dark)
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
  xl: 20,
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

// Registered with expo-font in App.tsx (see FontGate). Display is used
// sparingly — screen/section titles and hero numbers only; body carries
// everything read as prose; mono carries labels, timestamps, and codes.
export const fonts = {
  display: "ChakraPetch-Bold",
  bodyRegular: "PublicSans-Regular",
  bodyMedium: "PublicSans-Medium",
  bodySemiBold: "PublicSans-SemiBold",
  bodyBold: "PublicSans-Bold",
  mono: "PlexMono-Medium",
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

export const layout = {
  contentMaxWidth: 700,
  // NEVER spread this into a style that also sets a horizontal margin. Yoga resolves
  // `width: "100%"` against the parent's content box WITHOUT subtracting the child's
  // own margins, so with `alignSelf: "center"` the symmetric overflow exactly cancels
  // `marginHorizontal`/`marginLeft`/`marginRight` and the box paints full-bleed on
  // phone. Convert those margins to padding (transparent wrappers), or move this token
  // onto a plain wrapper View around the margined element (bordered/filled boxes).
  contentColumn: {
    width: "100%",
    maxWidth: 700,
    alignSelf: "center",
  } as const,
} as const;
