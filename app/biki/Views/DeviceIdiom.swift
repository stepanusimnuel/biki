import UIKit

// The app targets iPad Pro 11" (M5) and every fixed dimension elsewhere in
// Views/ is tuned against that — but a handful of layouts (GradingView's
// sidebar, the history table's header/footer, LaporanView's grade card
// grid) were sized assuming iPad-width space and crowd badly on an iPhone
// screen. `isPhoneIdiom` gates iPhone-only layout branches for exactly
// those spots. Deliberately checks the hardware idiom, not
// horizontalSizeClass — an iPad in Slide Over/Split View can also report
// compact, and that must keep using the iPad layout it was designed for.
let isPhoneIdiom = UIDevice.current.userInterfaceIdiom == .phone
