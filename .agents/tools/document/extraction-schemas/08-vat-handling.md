<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VAT Handling

## UK VAT Rate Detection

The extraction pipeline should detect VAT from these common patterns:

| Receipt Pattern | Meaning | Rate |
|----------------|---------|------|
| `VAT @ 20%` | Standard rate | 20 |
| `VAT @ 5%` | Reduced rate | 5 |
| `VAT: 0.00` or `Zero rated` | Zero-rated | 0 |
| `*` or `A` next to item | Standard rate (supermarket convention) | 20 |
| `B` next to an item | Zero-rated (supermarket convention) | 0 |
| `VAT Exempt` | Exempt | exempt |
| `No VAT` | Out of scope or not VAT registered | oos |
| `Reverse Charge` | Reverse charge (B2B services) | servrc |

## VAT Validation Rules

```text
1. If subtotal + vat_amount != total (within 0.02 tolerance):
   -> Flag for manual review

2. If vat_amount > 0 but no vendor_vat_number:
   -> Warning: VAT claimed without supplier VAT number

3. If line_items VAT sum != total vat_amount (within 0.05 tolerance):
   -> Recalculate from line items (line items take precedence)

4. If vat_rate not in [0, 5, 20, exempt, oos, servrc, cisrc, postgoods]:
   -> Flag as unusual rate for review

5. If no VAT marker or rate is present:
   -> Leave vat_rate unset; do not assume 20% or zero-rated treatment
```
