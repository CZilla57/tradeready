// context/ThemeContext.js
// Provides reactive theme (light/dark) throughout the app.
// Preference is persisted in AsyncStorage so it survives restarts.

import React, { createContext, useContext, useState, useEffect } from "react";
import { useColorScheme } from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import { lightColors, darkColors, shadow, darkShadow } from "../utils/theme";

const THEME_KEY = "__themePreference";

const ThemeContext = createContext({
  colors: lightColors,
  shadow: shadow,
  isDark: false,
  preference: "system",   // "light" | "dark" | "system"
  setTheme: () => {},
});

export function ThemeProvider({ children }) {
  const systemScheme = useColorScheme(); // "light" | "dark" | null
  const [preference, setPreference] = useState("system");

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

  function setTheme(pref) {
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

export function useThemeContext() {
  return useContext(ThemeContext);
}
