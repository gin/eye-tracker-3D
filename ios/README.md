# 3D Eye-Tracking Duck Hunt (iOS)

An iOS application and core engine for a 3D gaze-controlled Duck Hunt game powered by ARKit Face Tracking and custom gaze calibration algorithms.

---

## 🏗 Project Architecture

The repository inside `ios/` is organized into two primary layers:

1. **`DuckHunt` (Xcode App Target - `DuckHunt.xcodeproj`)**:
   - **UI & Views**: SwiftUI components (`HomeView`, `CalibrationView`, `GameView`, `ContentView`).
   - **Tracking**: ARKit integration (`ARFaceTrackingView`, `FaceTrackingFrame`). Each eye's optical axis is intersected with the plane of the device in camera space, so head and phone pose are folded in geometrically rather than left for the model to guess.
   - **Game Rendering**: 3D scene view and rendering logic (`GameRenderer`).
   - **App Logic**: Application lifecycle and persistent state (`AppModel`, `Persistence`).

2. **`DuckHuntCore` (Swift Package - `Package.swift`)**:
   - **`GazeCalibration.swift`**: Per-user affine correction over the geometric gaze estimate — kappa angle, ARKit gain and screen-table error — fitted by ridge regression on nine training dots and accepted only on four held-out validation dots.
   - **`OneEuroFilter.swift`**: Adaptive 1 Euro filtering for real-time gaze position jitter reduction without introducing lag.
   - **`GameEngine.swift` & `GameModels.swift`**: Core game mechanics, collision detection, duck spawning, timing, scoring, and mouth-blink trigger logic.
   - **`Geometry.swift`**: 2D/3D math helpers and point transformation primitives.
   - **`DeviceDisplay.swift`**: Active display size and TrueDepth camera placement per device, in millimetres. No public API reports these.

---

## 📋 Requirements

- **macOS**: macOS Sonoma 14.0 or later recommended.
- **Xcode**: Xcode 15.0 or later (supports Swift 6 / iOS 17 SDK).
- **Physical Device**: iPhone or iPad equipped with a **TrueDepth camera system** (iPhone X or newer, iPad Pro 11-inch/12.9-inch 3rd gen or newer with Face ID).
  > **Note**: ARKit Face Tracking (`ARFaceTrackingConfiguration`) requires a physical TrueDepth camera and **cannot** be executed inside the iOS Simulator. Non-tracking UI layout can be previewed in Simulator.

---

## 🛠 Procedure to Build and Run

### 1. Build & Run iOS App (Xcode)

1. Open `ios/DuckHunt.xcodeproj` in Xcode:
   ```bash
   cd ios
   open DuckHunt.xcodeproj
   ```
2. Select the **`DuckHunt`** scheme in the top toolbar.
3. Select your connected physical iOS device as the destination target.
4. Set up Development Team Signing:
   - Navigate to **Project Navigator** -> Select `DuckHunt` project -> Select `DuckHunt` target.
   - Select the **Signing & Capabilities** tab.
   - Under **Team**, select your Apple Developer Account / Development Team.
5. Press `Cmd + R` (or click **Play**) to build and deploy the app to your device.

---

## 🧪 Procedure to Test

You can run unit tests either via the Swift Package Manager CLI or directly within Xcode.

### Option A: Swift Package Manager CLI (Recommended for Core Logic)

You can build and test the `DuckHuntCore` logic in terminal without launching Xcode:

1. Open a terminal and navigate to the `ios/` folder:
   ```bash
   cd ios
   ```
2. **Build the Core Library**:
   ```bash
   swift build
   ```
3. **Run All Unit Tests**:
   ```bash
   swift test
   ```

The test suite executes 30 unit tests across 3 suites:
- `Native gaze calibration`: Validates affine recovery under rotation and axis swap, outlier rejection, fixation settling in millimetres, the held-out validation gate, coverage minimums, frame gating, the per-device screen table, and persistence.
- `One Euro gaze filter`: Validates noise attenuation and low-latency fast movement responsiveness.
- `Duck Hunt engine`: Validates round timers, duck hit detection, scoring, and mouth-open trigger controls.

### Option B: Xcode GUI

1. Open `ios/DuckHunt.xcodeproj` in Xcode.
2. Press `Cmd + U` (or menu item **Product > Test**) to execute all unit tests.

---

## 📁 Directory Structure

```
ios/
├── Package.swift               # Swift Package definition for DuckHuntCore
├── DuckHunt.xcodeproj          # Xcode project configuration
├── Sources/
│   └── DuckHuntCore/          # Core math, gaze calibration, filtering, and engine logic
├── Tests/
│   └── DuckHuntCoreTests/     # Unit test suites for DuckHuntCore
└── DuckHunt/                  # iOS SwiftUI application source
    ├── App/                   # App entrypoint and model
    ├── Game/                  # 3D renderer, game view, session state
    ├── Tracking/              # ARKit face/gaze camera tracking
    ├── UI/                    # SwiftUI views (Home, Calibration, Game)
    └── Resources/             # Assets, Info.plist, Privacy configuration
```
