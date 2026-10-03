// swift-tools-version: 5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "LAME",
    products: [
        .library(name: "LAME", targets: ["CLAME"]),
    ],
    targets: [
        .target(
            name: "CLAME",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("."),
            ]
        ),
    ]
)
