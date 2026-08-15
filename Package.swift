// swift-tools-version: 6.3
import PackageDescription

let package = Package(
	name: "swift-floating-rows",
	platforms: [.macOS(.v12)],
	products: [
		.library(
			name: "FloatingRowStack",
			targets: ["FloatingRowStack"]),
	],
	targets: [
		.target(
			name: "FloatingRowStack"),
	],
)
