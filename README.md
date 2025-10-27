# NDI Camera App

This repository contains an iOS SwiftUI application that turns your device into an NDI® compatible camera source. Clone the repository and open `NDIHXSender.xcodeproj` in Xcode 14 or newer to build and run the app on a device.

## Project Structure

- `NDIHXSender.xcodeproj` – Xcode project configured for the NDI camera app target
- `NDIHXSender/Sources` – Swift source grouped by feature area
  - `App` – SwiftUI app entry point, UI, and overlay rendering
  - `Capture` – Camera session management, permissions, and preview handling
  - `Analysis` – Pixel buffer analysis for histogram, zebra, and focus peaking overlays
  - `Streaming` – Placeholders for NDI transport, encoding, and audio pipeline integration
- `NDIHXSender/Resources` – App resources including the Info.plist and asset catalogs

The project builds for iOS 15.0+. You will need to provide your own signing team and integrate the Vizrt NDI SDK inside the placeholder methods before streaming to the network.
