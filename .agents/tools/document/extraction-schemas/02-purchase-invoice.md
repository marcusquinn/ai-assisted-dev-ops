<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Purchase Invoice Schema (Supplier Invoice)

Use for formal invoices received from suppliers with an invoice number.

## Shared Types

```python
from pydantic import BaseModel, Field
from typing import Optional
from enum import Enum


class VatRate(str, Enum):
    """UK VAT rates and special codes."""
    STANDARD = "20"
    REDUCED = "5"
    ZERO = "0"
    EXEMPT = "exempt"
    OUT_OF_SCOPE = "oos"
    REVERSE_CHARGE = "servrc"
    CIS_REVERSE = "cisrc"
    PVA_GOODS = "postgoods"


class PurchaseLineItem(BaseModel):
    """A single line item on a purchase invoice."""
    description: str = Field(
        ..., description="Item or service description", max_length=5000
    )
    quantity: float = Field(
        default=1.0, description="Number of units", ge=0
    )
    unit_price: float = Field(
        ..., description="Price per unit excluding VAT"
    )
    amount: float = Field(
        ..., description="Line total excluding VAT (quantity * unit_price)"
    )
    vat_rate: Optional[str] = Field(
        default=None,
        description="Explicitly extracted VAT rate percentage or special code"
    )
    vat_amount: Optional[float] = Field(
        default=None, description="VAT amount for this line (calculated if omitted)"
    )
    nominal_code: Optional[str] = Field(
        default=None,
        description="Accounting nominal code (e.g., 5000=General Purchases, "
        "7501=Postage, 7502=Telephone). Auto-categorised if omitted.",
        min_length=2, max_length=5
    )
```

## PurchaseInvoice Model

```python
class PurchaseInvoice(BaseModel):
    """
    Schema for supplier invoices received for goods/services purchased.

    Maps to: quickfile_purchase_create
    """
    # Vendor identification
    vendor_name: str = Field(
        ..., description="Supplier/vendor company name"
    )
    vendor_address: Optional[str] = Field(
        default=None, description="Supplier address (full or partial)"
    )
    vendor_vat_number: Optional[str] = Field(
        default=None, description="Supplier VAT registration number"
    )
    vendor_company_number: Optional[str] = Field(
        default=None, description="Supplier company registration number"
    )

    # Invoice identification
    invoice_number: str = Field(
        ..., description="Supplier's invoice reference number"
    )
    invoice_date: str = Field(
        ..., description="Date invoice was issued (YYYY-MM-DD)"
    )
    due_date: Optional[str] = Field(
        default=None, description="Payment due date (YYYY-MM-DD)"
    )
    purchase_order: Optional[str] = Field(
        default=None, description="Purchase order number if referenced"
    )

    # Financial totals
    subtotal: float = Field(
        ..., description="Total before VAT"
    )
    vat_amount: float = Field(
        default=0.0, description="Total VAT amount"
    )
    total: float = Field(
        ..., description="Total including VAT"
    )
    currency: str = Field(
        default="GBP", description="ISO 4217 currency code",
        min_length=3, max_length=3
    )

    # Line items
    line_items: list[PurchaseLineItem] = Field(
        default_factory=list,
        description="Individual line items (up to 500)"
    )

    # Payment info
    payment_terms: Optional[str] = Field(
        default=None, description="Payment terms (e.g., 'Net 30', '14 days')"
    )
    bank_details: Optional[str] = Field(
        default=None, description="Supplier bank details for payment"
    )

    # Metadata
    document_type: str = Field(
        default="purchase_invoice",
        description="Document classification"
    )
```
