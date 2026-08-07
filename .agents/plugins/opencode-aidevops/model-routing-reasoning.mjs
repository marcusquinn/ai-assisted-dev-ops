// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

export function withUnambiguousProviderFallbacks(policy) {
  const variantsByProvider = new Map();
  for (const [model, variant] of Object.entries(policy)) {
    const separator = model.indexOf("/");
    if (separator <= 0) continue;
    const provider = model.slice(0, separator);
    const variants = variantsByProvider.get(provider) || new Set();
    variants.add(variant);
    variantsByProvider.set(provider, variants);
  }
  const fallbacks = [...variantsByProvider]
    .filter(([provider, variants]) => !Object.hasOwn(policy, provider) && variants.size === 1)
    .map(([provider, variants]) => [provider, [...variants][0]]);
  return {...policy, ...Object.fromEntries(fallbacks)};
}
