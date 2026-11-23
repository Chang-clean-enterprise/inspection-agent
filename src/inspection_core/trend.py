"""Pure trend computation over per-lot means."""

from __future__ import annotations

from collections.abc import Sequence
from decimal import Decimal

Number = int | float | Decimal


def trend_indicator(means: Sequence[Number]) -> dict[str, str | int]:
    """Return the Trend_Indicator for per-lot means in ascending lot order.

    `direction` follows the sign of the last change. The count is the number of
    consecutive lot-to-lot changes with that same sign, counted backward from
    the last lot. It counts same-direction changes; it does not test proximity
    to a limit.
    """
    if len(means) < 2 or means[-1] == means[-2]:
        return {"direction": "flat", "consecutive_lots_toward_limit": 0}

    rising = means[-1] > means[-2]
    count = 0
    for i in range(len(means) - 1, 0, -1):
        change = means[i] - means[i - 1]
        if (change > 0) != rising or change == 0:
            break
        count += 1
    return {
        "direction": "rising" if rising else "falling",
        "consecutive_lots_toward_limit": count,
    }
