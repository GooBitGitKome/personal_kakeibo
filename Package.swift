// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonalKakeibo",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PersonalKakeiboDomain", targets: ["PersonalKakeiboDomain"]),
        .library(name: "PersonalKakeiboApplication", targets: ["PersonalKakeiboApplication"])
    ],
    targets: [
        .target(name: "PersonalKakeiboDomain", path: "PersonalKakeibo/Domain"),
        .target(name: "PersonalKakeiboApplication", dependencies: ["PersonalKakeiboDomain"], path: "PersonalKakeibo/Application"),
        .testTarget(name: "PersonalKakeiboDomainTests", dependencies: ["PersonalKakeiboDomain"]),
        .testTarget(name: "PersistenceTests", dependencies: ["PersonalKakeiboDomain", "PersonalKakeiboApplication"], path: ".", sources: ["PersonalKakeibo/Infrastructure", "PersonalKakeibo/Presentation/KakeiboViewModel.swift", "Tests/PersistenceTests"])
    ]
)
