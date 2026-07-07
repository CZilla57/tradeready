// context/SubscriptionContext.js
// Provides subscription state app-wide. Reads from RevenueCat SDK and
// re-checks whenever: the session changes, the app foregrounds, or a purchase
// completes (RC fires the customerInfoUpdateListener).
//
// When RC is not configured (dev / Expo Go), isSubscribed is always true.

import React, { createContext, useContext, useState, useEffect, useCallback } from 'react';
import { AppState } from 'react-native';
import { useAuth } from './AuthContext';
import {
  RC_CONFIGURED,
  getCustomerInfo,
  isEntitlementActive,
  isTrialingEntitlement,
  addCustomerInfoListener,
} from '../utils/subscription';

const SubscriptionContext = createContext(null);

export function SubscriptionProvider({ children }) {
  const { session } = useAuth();
  const [customerInfo, setCustomerInfo] = useState(null);
  const [fetchFailed, setFetchFailed]   = useState(false);
  const [isLoading, setIsLoading]       = useState(true);

  const refresh = useCallback(async () => {
    if (!session || !RC_CONFIGURED) {
      setIsLoading(false);
      return;
    }
    try {
      const info = await getCustomerInfo();
      setCustomerInfo(info);
      setFetchFailed(false);
    } catch {
      // RC error (network, config) — don't lock the user out; keep current state.
      setFetchFailed(true);
    } finally {
      setIsLoading(false);
    }
  }, [session]);

  // Reset and reload whenever the session changes.
  useEffect(() => {
    if (!session) {
      setCustomerInfo(null);
      setFetchFailed(false);
      setIsLoading(false);
      return;
    }
    setIsLoading(true);
    refresh();

    if (!RC_CONFIGURED) return;
    const removeListener = addCustomerInfoListener(info => {
      setCustomerInfo(info);
      setFetchFailed(false);
    });
    return removeListener;
  }, [session, refresh]);

  // Refresh when the app comes back to the foreground.
  useEffect(() => {
    const sub = AppState.addEventListener('change', state => {
      if (state === 'active' && session) refresh();
    });
    return () => sub.remove();
  }, [session, refresh]);

  // If RC is not configured OR fetch failed, be permissive (don't gate).
  const isSubscribed = !RC_CONFIGURED || fetchFailed || isEntitlementActive(customerInfo);
  const isTrialing   = isTrialingEntitlement(customerInfo);

  return (
    <SubscriptionContext.Provider value={{ customerInfo, isSubscribed, isTrialing, isLoading, refresh }}>
      {children}
    </SubscriptionContext.Provider>
  );
}

export function useSubscription() {
  return useContext(SubscriptionContext);
}
