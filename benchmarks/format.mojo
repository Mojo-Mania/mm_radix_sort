"""Small fixed-point and padding helpers so the benchmark tables line up."""


def fixed(value: Float64, decimals: Int = 2) -> String:
    """Formats `value` with exactly `decimals` digits after the point.

    Args:
        value: The number to format. Assumed non-negative.
        decimals: How many fractional digits to keep.

    Returns:
        The formatted number.
    """
    var scale = 1
    for _ in range(decimals):
        scale *= 10
    var scaled = Int(value * Float64(scale) + 0.5)
    var whole = scaled // scale
    var frac = scaled % scale
    var digits = String(frac)
    while digits.byte_length() < decimals:
        digits = String("0", digits)
    if decimals == 0:
        return String(whole)
    return String(whole, ".", digits)


def rjust(text: String, width: Int) -> String:
    """Right-aligns `text` in a field `width` wide.

    Args:
        text: The text to pad.
        width: The field width.

    Returns:
        The padded text, or `text` unchanged if it is already too wide.
    """
    var out = text.copy()
    while out.byte_length() < width:
        out = String(" ", out)
    return out


def ljust(text: String, width: Int) -> String:
    """Left-aligns `text` in a field `width` wide.

    Args:
        text: The text to pad.
        width: The field width.

    Returns:
        The padded text, or `text` unchanged if it is already too wide.
    """
    var out = text.copy()
    while out.byte_length() < width:
        out += " "
    return out
