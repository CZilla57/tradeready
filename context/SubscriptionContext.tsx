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

interface SubscriptionContextValue {
  customerInfo: unknown;
  isSubscribed: boolean;
  isTrialing: boolean;
  isLoading: boolean;
  refresh: () => Promise<void>;
  updateFromPurchase: (info: unknown) => void;
}

const SubscriptionContext = createContext<SubscriptionContextValue | null>(null);

export function SubscriptionProvider({ children }: { children: React.ReactNode }) {
  const { session } = useAuth();
  const [customerInfo, setCustomerInfo] = useState<unknown>(null);
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
      setFetchFailed(true);
    } finally {
      setIsLoading(false);
    }
  }, [session]);

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

  useEffect(() => {
    const sub = AppState.addEventListener('change', state => {
      if (state === 'active' && session) refresh();
    });
    return () => sub.remove();
  }, [session, refresh]);

  const isSubscribed = !RC_CONFIGURED || fetchFailed || isEntitlementActive(customerInfo);
  const isTrialing   = isTrialingEntitlement(customerInfo);

  const updateFromPurchase = useCallback((info: unknown) => {
    setCustomerInfo(info);
    setFetchFailed(false);
  }, []);

  return (
    <SubscriptionContext.Provider value={{ customerInfo, isSubscribed, isTrialing, isLoading, refresh, updateFromPurchase }}>
      {children}
    </SubscriptionContext.Provider>
  );
}

export function useSubscription(): SubscriptionContextValue {
  const ctx = useContext(SubscriptionContext);
  if (!ctx) throw new Error('useSubscription must be used within SubscriptionProvider');
  return ctx;
}
