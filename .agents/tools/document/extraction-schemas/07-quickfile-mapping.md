<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# QuickFile Field Mapping

## Purchase Invoice -> `quickfile_purchase_create`

Every call also requires `account`, supplied from the explicit QuickFile entity
alias selected by the user or workflow.

| Extracted Field | QuickFile Parameter | Notes |
|----------------|--------------------|----|
| `vendor_name` | Lookup via `quickfile_supplier_search` -> `supplierId` | Create supplier if not found |
| `invoice_number` | `supplierRef` | Supplier's reference number |
| `invoice_date` | `issueDate` | YYYY-MM-DD format |
| `currency` | `currency` | Default: GBP |
| `line_items[].description` | `lines[].description` | Max 5000 chars |
| `line_items[].quantity` | `lines[].quantity` | |
| `line_items[].unit_price` | `lines[].unitCost` | |
| `line_items[].vat_rate` | `lines[].vatPercentage` | Send only when explicitly extracted or reviewed; never assume 20% |
| `line_items[].nominal_code` | `lines[].nominalCode` | Auto-categorise if missing |

## Expense Receipt -> `quickfile_purchase_create`

Expense receipts require additional processing before QuickFile submission:

1. **Supplier resolution**: Search by `merchant_name`, create if not found
2. **Date handling**: Use `date` as `issueDate`
3. **Line item consolidation**: If no line items, create single line from `total`
4. **VAT review**: Preserve explicit per-item rates. For one consolidated line,
   the helper may calculate a rate from non-zero net and VAT totals; otherwise
   require account VAT posture or manual review.
5. **Category mapping**: Use `expense_category` or auto-categorise from merchant/items

| Extracted Field | QuickFile Parameter | Notes |
|----------------|--------------------|----|
| `merchant_name` | Lookup -> `supplierId` | Create supplier if not found |
| `receipt_number` | `supplierRef` | Optional |
| `date` | `issueDate` | |
| `total` | Derived from lines | |
| `items[].name` | `lines[].description` | |
| `items[].price` | `lines[].unitCost` (qty=1) | |
| `expense_category` | `lines[].nominalCode` | All lines same category |
