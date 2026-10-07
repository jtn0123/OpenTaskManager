import Foundation

extension Format {
    /// A change in size with its sign: "+200 MB", "−1.50 GB", "0 B". The
    /// minus is a real minus sign, as wide as the plus.
    public static func byteChange(_ delta: Int64) -> String {
        if delta == 0 { return "0 B" }
        return (delta > 0 ? "+" : "\u{2212}") + bytes(delta.magnitude)
    }

    /// A growth (`grew`) or shrinkage of `amount`, with "or more" when the
    /// figure is only the least it could be.
    public static func byteChange(_ amount: UInt64, grew: Bool, exact: Bool) -> String {
        let signed = amount == 0 ? "0 B" : (grew ? "+" : "\u{2212}") + bytes(amount)
        return exact ? signed : signed + " or more"
    }

    /// What a saved scan says a size was: "735 MB", "at most 6.00 MB",
    /// "10.0 MB–20.0 MB", "40.0 MB or more", or "unknown".
    public static func bytes(_ estimate: DiskSizeEstimate) -> String {
        if estimate.isExact { return bytes(estimate.low) }
        if !estimate.isBounded { return estimate.low > 0 ? "\(bytes(estimate.low)) or more" : "unknown" }
        if estimate.low == 0 { return "at most \(bytes(estimate.high))" }
        return "\(bytes(estimate.low))\u{2013}\(bytes(estimate.high))"
    }
}
