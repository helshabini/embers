# Shared by every language: what is never translated, and the English wording of counts.

# Keys that are not words: numbers, symbols, a placeholder alone. Left as the source.
untranslatable = {"%", "%lld", "0", "0.00", "%@: %@", "Embers"}

# English keys with a count, worded for one and for many.
en_plurals = {
    "%lld accounts": ("%lld account", "%lld accounts"),
    "%lld categories": ("%lld category", "%lld categories"),
    "%lld months": ("%lld month", "%lld months"),
    "%lld transactions": ("%lld transaction", "%lld transactions"),
    "Delete %lld transactions?": ("Delete %lld transaction?", "Delete %lld transactions?"),
    "%lld uncategorized transactions": ("%lld uncategorized transaction", "%lld uncategorized transactions"),
    "%lld days old": ("%lld day old", "%lld days old"),
    "money assigned in %lld months": ("money assigned in %lld month", "money assigned in %lld months"),
    "Import %lld Transactions": ("Import %lld Transaction", "Import %lld Transactions"),
    "The statement agrees. Reconciling will lock %lld entries as checked.": (
        "The statement agrees. Reconciling will lock %lld entry as checked.",
        "The statement agrees. Reconciling will lock %lld entries as checked.",
    ),
    "This removes the transaction and its %lld split lines.": (
        "This removes the transaction and its %lld split line.",
        "This removes the transaction and its %lld split lines.",
    ),
}
