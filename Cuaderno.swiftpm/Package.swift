// swift-tools-version: 5.9

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Cuaderno",
    platforms: [
        .iOS("17.5")
    ],
    products: [
        .iOSApplication(
            name: "Cuaderno",
            targets: ["AppModule"],
            bundleIdentifier: "com.matias.cuaderno",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .pencil),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .microphone(purposeString: "Para grabar el audio de la clase junto a tus apuntes.")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
