import OTMKit
import SwiftUI

extension ConnectionHistoryColumn: FittingColumn {
    var minWidth: CGFloat {
        switch self {
        case .process: 200
        case .endpoints: 160
        case .transport: 60
        case .seen: 140
        case .ended: 110
        }
    }

    var maxWidth: CGFloat? {
        switch self {
        case .transport: 80
        case .seen: 180
        case .ended: 200
        case .process, .endpoints: nil
        }
    }

    var priority: Int? {
        switch self {
        case .transport: 1
        case .seen: 2
        case .process, .endpoints, .ended: nil
        }
    }
}
