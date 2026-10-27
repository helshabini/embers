#!/usr/bin/env python3
"""Writes a fictional budget, in the shape of a YNAB export, for the website's screenshots.

The screenshots are public, so they must never come from a real budget. Every name and figure
here is invented. Seed it into the UI-test store and run `ScreenCatalogUITests`:

    python3 web/tools/make-demo-budget.py /tmp/demo.zip
    cd Packages/EmbersCore && swift run seed-store /tmp/demo.zip "$C/Embers-UITests.store"

Available is computed here the way the export states it, so the importer has nothing to
reconcile: no category is ever overspent, and the card is paid off each month for exactly what
was charged to it the month before.
"""
import datetime as dt
import io
import random
import sys
import zipfile

random.seed(7)

TODAY = dt.date(2026, 10, 27)
MONTHS = [(2026, m) for m in range(1, 12)]  # through November, which is planned ahead

CHECKING = "Everyday Checking (USD)"
SAVINGS = "High-Yield Savings (USD)"
CARD = "Travel Card (EUR)"
CASH = "Cash (GBP)"
BROKERAGE = "Brokerage"

# group, category, monthly assignment, (payees, low, high, times per month, account)
PLAN = [
    ("Bills", "Rent", 1650, (["Maple Street Lettings"], 1650, 1650, 1, CHECKING)),
    ("Bills", "Electricity", 95, (["Brightline Energy"], 62, 94, 1, CHECKING)),
    ("Bills", "Internet", 55, (["Fibrenet"], 55, 55, 1, CHECKING)),
    ("Bills", "Phone", 35, (["Northwave Mobile"], 35, 35, 1, CHECKING)),
    ("Everyday", "Groceries", 520, (["Green Basket", "Corner Market", "FreshCo"], 28, 96, 6, CHECKING)),
    ("Everyday", "Dining Out", 180, (["Trattoria Luce", "Noodle House", "The Daily Grind"], 14, 48, 4, CARD)),
    ("Everyday", "Transport", 140, (["City Transit", "Metro Fuel"], 18, 42, 3, CHECKING)),
    ("Everyday", "Coffee", 45, (["The Daily Grind", "Bean There"], 4, 7, 6, CASH)),
    ("Subscriptions", "Streaming", 28, (["StreamBox"], 16, 16, 1, CARD)),
    ("Subscriptions", "Cloud Storage", 10, (["Skyvault"], 3, 3, 1, CARD)),
    ("Subscriptions", "Gym", 45, (["Peak Fitness"], 45, 45, 1, CHECKING)),
    ("Goals", "Summer Trip", 450, None),
    ("Goals", "Emergency Fund", 1200, None),
    ("Goals", "New Laptop", 250, None),
    ("Goals", "Investing", 400, None),
    ("Goals", "Car Service", 80, None),
    ("Goals", "Home Insurance", 120, None),
    ("Fun", "Hobbies", 80, (["Craft & Co", "Vinyl Corner"], 18, 55, 1, CARD)),
    ("Fun", "Gifts", 60, (["Paper & Ribbon"], 25, 50, 1, CARD)),
]

register = []  # (account, date, payee, group, category, memo, amount, cleared)


def add(account, date, payee, group, category, amount, memo="", cleared=None):
    if cleared is None:
        cleared = "Uncleared" if date > TODAY - dt.timedelta(days=4) else (
            "Reconciled" if date < dt.date(2026, 10, 1) else "Cleared")
    register.append((account, date, payee, group, category, memo, round(amount, 2), cleared))


start = dt.date(2026, 1, 1)
for account, amount in [(CHECKING, 2840.00), (SAVINGS, 6200.00), (CARD, 0.00), (CASH, 120.00)]:
    add(account, start, "Starting Balance", "Inflow", "Ready to Assign", amount)
add(BROKERAGE, start, "Starting Balance", "", "", 14500.00)

for year, month in MONTHS:
    first = dt.date(year, month, 1)
    if first > TODAY:
        break
    add(CHECKING, first, "Lumen Design Studio", "Inflow", "Ready to Assign", 5200.00, "Salary")
    if month % 3 == 0:
        add(SAVINGS, dt.date(year, month, 28), "Interest", "Inflow", "Ready to Assign", 21.40)
    add(BROKERAGE, dt.date(year, month, 28), "Market value", "", "", random.uniform(-180, 420))

    for group, category, _, spending in PLAN:
        if not spending:
            continue
        payees, low, high, times, account = spending
        for i in range(times):
            day = 1 + i * (27 // times) + random.randint(0, max(0, 27 // times - 1))
            date = dt.date(year, month, min(day, 28))
            if date > TODAY:
                continue
            amount = random.uniform(low, high) if low != high else low
            memo = ""
            if account == CARD:
                memo = f"EUR {amount / 1.08:,.2f}"
            elif account == CASH:
                memo = f"GBP {amount / 1.27:,.2f}"
            add(account, date, random.choice(payees), group, category, -amount, memo)

    if month == 7:
        add(CARD, dt.date(2026, 7, 14), "Hotel Miramar", "Goals", "Summer Trip", -1380.00, "EUR 1,277.78 · 4 nights")
        add(CARD, dt.date(2026, 7, 16), "Aerolinea", "Goals", "Summer Trip", -420.00, "EUR 388.89")

# The card is paid on the 5th for everything charged to it the month before.
for year, month in MONTHS:
    pay_date = dt.date(year, month, 5)
    if month == 1 or pay_date > TODAY:
        continue
    owed = -sum(r[6] for r in register
                if r[0] == CARD and r[4] and (r[1].year, r[1].month) == (year, month - 1))
    add(CHECKING, pay_date, f"Transfer : {CARD}", "", "", -owed)
    add(CARD, pay_date, f"Transfer : {CHECKING}", "", "", owed)

# Monthly moves. Savings and cash stay on budget, so they need no category; the brokerage is
# tracked, so the money leaving the budget for it is spent from a category on the budget side only.
for year, month in MONTHS:
    date = dt.date(year, month, 2)
    if date > TODAY:
        continue
    for target, amount, category in [(SAVINGS, 1000.00, ""), (CASH, 60.00, ""), (BROKERAGE, 400.00, "Investing")]:
        add(CHECKING, date, f"Transfer : {target}", "Goals" if category else "", category, -amount)
        add(target, date, f"Transfer : {CHECKING}", "", "", amount)

# What is coming: next month's bills, scheduled.
for category, payee, amount, day in [("Rent", "Maple Street Lettings", 1650, 1), ("Internet", "Fibrenet", 55, 3),
                                     ("Phone", "Northwave Mobile", 35, 4), ("Gym", "Peak Fitness", 45, 6)]:
    add(CHECKING, dt.date(2026, 11, day), payee, "Subscriptions" if category == "Gym" else "Bills",
        category, -amount, cleared="Uncleared")

# The plan: assignments, and what each category did with them.
plan_rows = []
available = {}
card_payment_available = 0.0
for year, month in MONTHS:
    label = dt.date(year, month, 1).strftime("%b %Y")
    in_month = [r for r in register if (r[1].year, r[1].month) == (year, month)]
    for group, category, assigned, _ in PLAN:
        activity = sum(r[6] for r in in_month if r[4] == category)
        available[category] = available.get(category, 0.0) + assigned + activity
        assert available[category] >= -0.005, (label, category, available[category])
        plan_rows.append((label, group, category, assigned, activity, available[category]))
    # A card's payment category gains what is spent on the card and loses what is paid to it.
    spent = -sum(r[6] for r in in_month if r[0] == CARD and r[4])
    paid = sum(r[6] for r in in_month if r[0] == CARD and r[2].startswith("Transfer"))
    activity = spent - paid
    card_payment_available += activity
    plan_rows.insert(len(plan_rows) - len(PLAN),
                     (label, "Credit Card Payments", CARD, 0.0, activity, card_payment_available))


def money(value):
    return f"-${-value:.2f}" if value < -0.0049 else f"${abs(value):.2f}"


plan_csv = io.StringIO()
plan_csv.write('"Month","Category Group/Category","Category Group","Category","Assigned","Activity","Available"\n')
for label, group, category, assigned, activity, avail in plan_rows:
    plan_csv.write(f'"{label}","{group}: {category}","{group}","{category}",'
                   f'{money(assigned)},{money(activity)},{money(avail)}\n')

register_csv = io.StringIO()
register_csv.write('"Account","Flag","Date","Payee","Category Group/Category","Category Group","Category",'
                   '"Memo","Outflow","Inflow","Cleared"\n')
for account, date, payee, group, category, memo, amount, cleared in sorted(register, key=lambda r: r[1], reverse=True):
    joined = f"{group}: {category}" if category else ""
    outflow, inflow = (money(-amount), "$0.00") if amount < 0 else ("$0.00", money(amount))
    register_csv.write(f'"{account}","","{date:%m/%d/%Y}","{payee}","{joined}","{group}","{category}",'
                       f'"{memo}",{outflow},{inflow},"{cleared}"\n')

with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("Demo Budget - Plan.csv", "﻿" + plan_csv.getvalue())
    archive.writestr("Demo Budget - Register.csv", "﻿" + register_csv.getvalue())
print(f"wrote {sys.argv[1]}: {len(plan_rows)} plan rows, {len(register)} register rows")
