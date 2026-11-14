import SwiftUI

// The macOS 27 CLT SDK exports a same-named `State` macro without its plugin, so views and apps
// spell the property wrapper through this alias.
public typealias ViewState = SwiftUI.State
