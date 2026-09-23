//
//  SidebarSectionMetrics.swift
//  UnpeelNative
//
//  Fork-only: sidebar sections. Geometry shared by the section stack and
//  the upstream list code it hosts.
//

import SwiftUI

enum SidebarSectionMetrics {
    static let headerHeight: CGFloat = 22
    static let separatorHeight: CGFloat = 1
    /// Grab area of a divider, centred on its 1 pt line.
    static let dividerHitHeight: CGFloat = 6
    /// The stack starts under the traffic-light strip (a window drag area).
    static let stackTopInset: CGFloat = Theme.titlebarHeight
    /// First-row clearance inside the PROJECTS section, shared by both
    /// workspace carousel pages (was 48 pt when rows scrolled under the
    /// traffic lights; the section header now provides the separation).
    static let projectsTopInset: CGFloat = 4
    /// Height over which PROJECTS rows fade out under the section header.
    static let projectsFadeRamp: CGFloat = 14
    static let collapseAnimation = Animation.easeInOut(duration: 0.15)
}
