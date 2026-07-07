import React, { createContext, useContext, useState, useEffect } from "react";
import { useColorScheme } from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { lightColors, darkColors, shadow, darkShadow, type ColorScheme, type ShadowScheme } from "../utils/theme";

const THEME_KEY = "__themePreference";

export type ThemePreference = "light" | "dark" | "system";

interface ThemeContextValue {
  colors: ColorScheme;
  shadow: ShadowScheme;
  isDark: boolean;
  preference: ThemePreference;
  setTheme: (pref: ThemePreference) => void;
}

const ThemeContext = createContext<ThemeContextValue>({
  colors: lightColors,
  shadow: shadow,
  isDark: false,
  preference: "system",
  setTheme: () => {},
});

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const systemScheme = useColorScheme();
  const [preference, setPreference] = useState<ThemePreference>("system");

  useEffect(() => {
    AsyncStorage.getItem(THEME_KEY).then((v) => {
      if (v === "light" || v === "dark" || v === "system") {
        setPreference(v);
      }
    });
  }, []);

  const isDark =
    preference === "dark" ||
    (preference === "system" && systemScheme === "dark");

  const colors = isDark ? darkColors : lightColors;
  const currentShadow = isDark ? darkShadow : shadow;

  function setTheme(pref: ThemePreference) {
    setPreference(pref);
    AsyncStorage.setItem(THEME_KEY, pref);
  }

  return (
    <ThemeContext.Provider
      value={{ colors, shadow: currentShadow, isDark, preference, setTheme }}
    >
      {children}
    </ThemeContext.Provider>
  );
}

export function useThemeContext(): ThemeContextValue {
  return useContext(ThemeContext);
}
